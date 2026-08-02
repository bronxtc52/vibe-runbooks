#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VIBE_MAC_ROOT="$SCRIPT_DIR"
export VIBE_MAC_ROOT

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"

REPAIR=0
ISSUES=0
BLOCKER=0
REPAIR_MODE_ROOT=0
REPAIR_STALE_LOCK=0

usage() {
  printf '%s\n' \
    "Запуск: /bin/bash ./doctor.sh [--dry-run|--repair]" \
    "--repair выполняет только показанные allowlisted исправления после да."
}

record_issue() {
  ISSUES=$((ISSUES + 1))
  ui_warn "$1"
}

record_blocker() {
  BLOCKER=1
  ui_fail "$1"
}

validate_json_file() {
  local file expected_schema label schema
  file="$1"
  expected_schema="$2"
  label="$3"
  if [ ! -e "$file" ]; then
    record_issue "$label отсутствует."
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    record_blocker "$label должен быть обычным файлом, не symlink."
    return 0
  fi
  if ! json_lint "$file"; then
    record_blocker "$label повреждён."
    return 0
  fi
  schema="$(json_extract_raw "$file" schema_version 2>/dev/null)" || {
    record_blocker "$label не содержит schema_version."
    return 0
  }
  if [ "$schema" != "$expected_schema" ]; then
    record_blocker "$label имеет неизвестную schema: $schema."
  fi
}

safe_current_target() {
  local current target version
  current="$VIBE_MAC_RUNTIME_ROOT/current"
  if [ ! -e "$current" ] && [ ! -L "$current" ]; then
    return 0
  fi
  if [ ! -L "$current" ]; then
    record_blocker "current должен быть symlink."
    return 0
  fi
  target="$(/usr/bin/readlink "$current")" || {
    record_blocker "current symlink не читается."
    return 0
  }
  case "$target" in releases/*) ;; *)
    record_blocker "current выходит за allowlist releases/<version>."
    return 0
    ;;
  esac
  version="${target#releases/}"
  case "$version" in
    [A-Za-z0-9]*)
      case "$version" in *[!A-Za-z0-9._-]*|*..*)
        record_blocker "current содержит небезопасную version."
        return 0
        ;;
      esac
      ;;
    *)
      record_blocker "current содержит небезопасную version."
      return 0
      ;;
  esac
  if [ "$target" != "releases/$version" ]; then
    record_blocker "current содержит extra path."
    return 0
  fi
  if [ ! -d "$VIBE_MAC_RUNTIME_ROOT/$target" ] ||
    [ -L "$VIBE_MAC_RUNTIME_ROOT/$target" ]; then
    record_blocker "current указывает не на обычный release-каталог."
  fi
}

runtime_mode_check() {
  local mode
  [ -d "$VIBE_MAC_RUNTIME_ROOT" ] || return 0
  if [ -L "$VIBE_MAC_RUNTIME_ROOT" ]; then
    record_blocker "Runtime root не может быть symlink."
    return 0
  fi
  mode="$(file_mode "$VIBE_MAC_RUNTIME_ROOT")" || {
    record_blocker "Не удалось прочитать mode runtime root."
    return 0
  }
  if [ "$mode" != 700 ]; then
    record_issue "Runtime root имеет mode $mode вместо 700."
    REPAIR_MODE_ROOT=1
  fi
}

validate_manifest_file_evidence() {
  if ! manifest_validate_file_entry \
    zprofile .zprofile managed_block zprofile zprofile ||
    ! manifest_validate_file_entry \
      zshrc .zshrc managed_block zshrc zshrc ||
    ! manifest_validate_file_entry \
      ghostty \
      "Library/Application Support/com.mitchellh.ghostty/config" \
      managed_block ghostty ghostty-config ||
    ! manifest_validate_file_entry \
      aliases .config/vibe-mac/aliases.zsh owned_file "" aliases-zsh ||
    ! manifest_validate_file_entry \
      starship .config/starship.toml owned_file "" starship-toml ||
    ! manifest_validate_file_entry \
      mise-global .config/mise/config.toml owned_file "" mise-global; then
    record_blocker "Manifest file/backup evidence не прошёл allowlist/hash."
  fi
}

managed_block_sha() {
  local target block_id begin end
  target="$1"
  block_id="$2"
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"
  /usr/bin/awk -v begin="$begin" -v end="$end" '
    $0 == begin {
      if (inside || seen) exit 40
      inside = 1
      seen = 1
      next
    }
    $0 == end {
      if (!inside) exit 41
      inside = 0
      closed = 1
      next
    }
    inside { print }
    END {
      if (!seen || !closed || inside) exit 42
    }
  ' "$target" | sha256_stdin
}

inspect_owned_file() {
  local id target kind block_id owned expected actual
  id="$1"
  target="$2"
  kind="$3"
  block_id="$4"
  owned="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned" 2>/dev/null || true)"
  [ "$owned" = true ] || return 0
  expected="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.applied_sha")" || {
    record_blocker "File evidence $id не содержит applied SHA."
    return 0
  }
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    record_issue "Owned target $id отсутствует."
    return 0
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    record_blocker "Owned target $id стал symlink/special path."
    return 0
  fi
  case "$kind" in
    owned_file)
      actual="$(sha256_file "$target")" || {
        record_blocker "Owned target $id нельзя хэшировать."
        return 0
      }
      ;;
    managed_block)
      actual="$(managed_block_sha "$target" "$block_id" 2>/dev/null)" || {
        record_issue "Managed block $id отсутствует или malformed."
        return 0
      }
      ;;
    *)
      record_blocker "Unknown owned file kind: $kind."
      return 0
      ;;
  esac
  if [ "$actual" != "$expected" ]; then
    record_issue "Owned target $id изменён после установки."
  fi
}

inspect_manifest_targets() {
  inspect_owned_file zprofile "$HOME/.zprofile" managed_block zprofile
  inspect_owned_file zshrc "$HOME/.zshrc" managed_block zshrc
  inspect_owned_file ghostty \
    "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
    managed_block ghostty
  inspect_owned_file aliases \
    "$HOME/.config/vibe-mac/aliases.zsh" owned_file ""
  inspect_owned_file starship \
    "$HOME/.config/starship.toml" owned_file ""
  inspect_owned_file mise-global \
    "$HOME/.config/mise/config.toml" owned_file ""
}

lock_entry_count() {
  /usr/bin/find "$VIBE_MAC_LOCK_DIR" -mindepth 1 -maxdepth 1 -print |
    /usr/bin/wc -l | /usr/bin/tr -d ' '
}

lock_is_well_formed() {
  local file pid version started count
  [ "$VIBE_MAC_LOCK_DIR" = "$VIBE_MAC_STATE_DIR/install.lock.d" ] || return 1
  [ -d "$VIBE_MAC_LOCK_DIR" ] || return 1
  [ ! -L "$VIBE_MAC_LOCK_DIR" ] || return 1
  count="$(lock_entry_count)"
  [ "$count" = 3 ] || return 1
  for file in pid version started_at; do
    [ -f "$VIBE_MAC_LOCK_DIR/$file" ] || return 1
    [ ! -L "$VIBE_MAC_LOCK_DIR/$file" ] || return 1
  done
  pid="$(/bin/cat "$VIBE_MAC_LOCK_DIR/pid")" || return 1
  version="$(/bin/cat "$VIBE_MAC_LOCK_DIR/version")" || return 1
  started="$(/bin/cat "$VIBE_MAC_LOCK_DIR/started_at")" || return 1
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  case "$version" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$started" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      ;;
    *) return 1 ;;
  esac
}

process_exists() {
  local pid
  pid="$1"
  if [ -x /bin/ps ]; then
    /bin/ps -p "$pid" >/dev/null 2>&1
  else
    /usr/bin/ps -p "$pid" >/dev/null 2>&1
  fi
}

diagnose_lock() {
  local pid
  if [ ! -e "$VIBE_MAC_LOCK_DIR" ] && [ ! -L "$VIBE_MAC_LOCK_DIR" ]; then
    return 0
  fi
  if ! lock_is_well_formed; then
    record_blocker "Lock повреждён или содержит неожиданные entries."
    return 0
  fi
  pid="$(/bin/cat "$VIBE_MAC_LOCK_DIR/pid")"
  if process_exists "$pid"; then
    record_issue "Обнаружен активный lock процесса $pid."
  else
    record_issue "Обнаружен stale lock процесса $pid."
    REPAIR_STALE_LOCK=1
  fi
}

diagnose() {
  ISSUES=0
  BLOCKER=0
  REPAIR_MODE_ROOT=0
  REPAIR_STALE_LOCK=0

  validate_json_file "$VIBE_MAC_STATE_FILE" "$STATE_SCHEMA_VERSION" progress.json
  validate_json_file "$VIBE_MAC_MANIFEST_FILE" "$MANIFEST_SCHEMA_VERSION" manifest.json
  safe_current_target
  runtime_mode_check
  validate_manifest_file_evidence
  if [ "$BLOCKER" -eq 0 ]; then
    inspect_manifest_targets
  fi
  diagnose_lock

  if [ "$BLOCKER" -eq 0 ] && [ "$ISSUES" -eq 0 ]; then
    ui_success "Doctor: проблем не найдено."
  else
    ui_info "Doctor: проблем $ISSUES; integrity blocker: $BLOCKER."
  fi
}

show_repair_plan() {
  printf '%s\n' "План ремонта:"
  if [ "$REPAIR_MODE_ROOT" = 1 ]; then
    printf '  - chmod 0700 только %s\n' "$VIBE_MAC_RUNTIME_ROOT"
  fi
  if [ "$REPAIR_STALE_LOCK" = 1 ]; then
    printf '  - удалить доказанно stale lock %s\n' "$VIBE_MAC_LOCK_DIR"
  fi
  if [ "$REPAIR_MODE_ROOT" = 0 ] && [ "$REPAIR_STALE_LOCK" = 0 ]; then
    printf '%s\n' "  - allowlisted автоматических действий нет"
  fi
}

repair_runtime_mode() {
  [ "$VIBE_MAC_RUNTIME_ROOT" = "$HOME/.vibe-mac" ] ||
    is_test_mode || return 2
  [ -d "$VIBE_MAC_RUNTIME_ROOT" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT" ] || return 2
  /bin/chmod 0700 "$VIBE_MAC_RUNTIME_ROOT"
}

remove_stale_lock() {
  local pid file
  lock_is_well_formed || return 2
  pid="$(/bin/cat "$VIBE_MAC_LOCK_DIR/pid")"
  if process_exists "$pid"; then
    return 2
  fi
  for file in pid version started_at; do
    /bin/unlink "$VIBE_MAC_LOCK_DIR/$file"
  done
  /bin/rmdir "$VIBE_MAC_LOCK_DIR"
}

case "${1:-}" in
  "")
    ;;
  --dry-run)
    ;;
  --repair)
    REPAIR=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

diagnose
if [ "$BLOCKER" -ne 0 ]; then
  exit 2
fi
if [ "$REPAIR" = 0 ]; then
  [ "$ISSUES" -eq 0 ] && exit 0
  exit 1
fi

show_repair_plan
if [ "${DRY_RUN:-0}" = 1 ]; then
  [ "$ISSUES" -eq 0 ] && exit 0
  exit 1
fi
if [ "$REPAIR_MODE_ROOT" = 0 ] && [ "$REPAIR_STALE_LOCK" = 0 ]; then
  [ "$ISSUES" -eq 0 ] && exit 0
  exit 1
fi
if ! ui_confirm "Применить только этот план ремонта?"; then
  ui_warn "Ремонт отменён; изменений нет."
  exit 1
fi

if [ "$REPAIR_MODE_ROOT" = 1 ]; then
  repair_runtime_mode || {
    ui_fail "Mode не исправлен: повторная safety-проверка не прошла."
    exit 2
  }
fi
if [ "$REPAIR_STALE_LOCK" = 1 ]; then
  remove_stale_lock || {
    ui_fail "Stale lock не удалён: повторная safety-проверка не прошла."
    exit 2
  }
fi

diagnose
if [ "$BLOCKER" -ne 0 ]; then
  exit 2
fi
[ "$ISSUES" -eq 0 ]
