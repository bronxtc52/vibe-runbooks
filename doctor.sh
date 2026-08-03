#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(/bin/realpath "$0" 2>/dev/null)" || {
  /usr/bin/printf '%s\n' 'Ошибка: doctor.sh path нельзя канонизировать.' >&2
  exit 2
}
case "$SCRIPT_PATH" in
  /*/*) SCRIPT_DIR="${SCRIPT_PATH%/*}" ;;
  *)
    /usr/bin/printf '%s\n' 'Ошибка: doctor.sh path небезопасен.' >&2
    exit 2
    ;;
esac
VIBE_MAC_ROOT="$SCRIPT_DIR"
export VIBE_MAC_ROOT

# `git archive` replaces this literal with the exact release commit. Source
# checkouts retain test seams; packaged doctor execution is validated before
# any release-controlled file is sourced.
# shellcheck disable=SC2016
VIBE_MAC_DOCTOR_BUILD_COMMIT='$Format:%H$'
# shellcheck disable=SC2016
case "$VIBE_MAC_DOCTOR_BUILD_COMMIT" in
  *'$Format:'*)
    VIBE_MAC_DOCTOR_BUILD_KIND=source
    ;;
  *)
    if [ "${#VIBE_MAC_DOCTOR_BUILD_COMMIT}" -ne 40 ] ||
      ! printf '%s\n' "$VIBE_MAC_DOCTOR_BUILD_COMMIT" |
      LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{40}$'; then
      printf '%s\n' 'Ошибка: неизвестный build marker doctor.sh.' >&2
      exit 2
    fi
    VIBE_MAC_DOCTOR_BUILD_KIND=release
    VIBE_MAC_TEST_MODE=0
    export VIBE_MAC_TEST_MODE
    ;;
esac
readonly VIBE_MAC_DOCTOR_BUILD_COMMIT VIBE_MAC_DOCTOR_BUILD_KIND

doctor_entrypoint_integrity_fail() {
  printf 'Ошибка: active release vibe-mac повреждён: %s\n' "$1" >&2
  exit 2
}

doctor_entrypoint_file_mode() {
  if /usr/bin/stat -f '%Lp' "$1" >/dev/null 2>&1; then
    /usr/bin/stat -f '%Lp' "$1"
  else
    /usr/bin/stat -c '%a' "$1"
  fi
}

doctor_entrypoint_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

doctor_entrypoint_sha256_stdin() {
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

doctor_entrypoint_sha_marker() {
  local marker value
  marker="$1"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  value="$(/bin/cat "$marker")" || return 2
  [ "${#value}" -eq 64 ] || return 2
  case "$value" in *[!0-9a-f]*) return 2 ;; esac
  printf '%s\n' "$value"
}

doctor_entrypoint_release_tree_sha256() {
  local root absolute path mode file_sha
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  /usr/bin/find "$root" -mindepth 1 -print0 |
      while IFS= read -r -d '' absolute; do
        case "$absolute" in
          "$root"/*) path=".${absolute#"$root"}" ;;
          *) exit 2 ;;
        esac
        case "$path" in *[[:cntrl:]]*) exit 2 ;; esac
        case "$path" in ./*) ;; *) exit 2 ;; esac
        case "$path" in
          *\\*|*"/../"*|*"/./"*|*"//"*) exit 2 ;;
        esac
        if [ -L "$absolute" ]; then
          exit 2
        elif [ -f "$absolute" ] || [ -d "$absolute" ]; then
          :
        else
          exit 2
        fi
        case "$path" in
          ./.bundle-sha256|./.bundle-tree-sha256) continue ;;
        esac
        printf '%s\n' "$path"
      done | LC_ALL=C /usr/bin/sort |
      while IFS= read -r path; do
        absolute="$root/${path#./}"
        if [ -L "$absolute" ]; then
          exit 2
        elif [ -f "$absolute" ]; then
          mode="$(doctor_entrypoint_file_mode "$absolute")" || exit 2
          file_sha="$(doctor_entrypoint_sha256_file "$absolute")" || exit 2
          printf 'F\t%s\t%s\t%s\n' \
            "$mode" "$file_sha" "$path"
        elif [ -d "$absolute" ]; then
          mode="$(doctor_entrypoint_file_mode "$absolute")" || exit 2
          printf 'D\t%s\t-\t%s\n' "$mode" "$path"
        else
          exit 2
        fi
      done |
      doctor_entrypoint_sha256_stdin
}

doctor_entrypoint_verify_active_release() {
  local runtime releases current target version release release_physical
  local archive_sha expected_tree actual_tree
  case "${HOME:-}" in
    /*) ;;
    *) doctor_entrypoint_integrity_fail 'HOME должен быть absolute path.' ;;
  esac
  case "$HOME" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      doctor_entrypoint_integrity_fail 'HOME содержит control character.'
      ;;
  esac
  [ -d "$HOME" ] && [ ! -L "$HOME" ] ||
    doctor_entrypoint_integrity_fail 'HOME отсутствует или является symlink.'

  runtime="$HOME/.vibe-mac"
  releases="$runtime/releases"
  current="$runtime/current"
  [ -d "$runtime" ] && [ ! -L "$runtime" ] ||
    doctor_entrypoint_integrity_fail 'runtime root небезопасен.'
  [ -d "$releases" ] && [ ! -L "$releases" ] ||
    doctor_entrypoint_integrity_fail 'releases небезопасен.'
  [ -L "$current" ] ||
    doctor_entrypoint_integrity_fail 'current должен быть symlink.'
  target="$(/usr/bin/readlink "$current")" ||
    doctor_entrypoint_integrity_fail 'current не читается.'
  case "$target" in
    releases/[A-Za-z0-9]*)
      version="${target#releases/}"
      case "$version" in
        *[!A-Za-z0-9._-]*|*..*)
          doctor_entrypoint_integrity_fail \
            'current содержит небезопасную version.'
          ;;
      esac
      ;;
    *)
      doctor_entrypoint_integrity_fail \
        'current выходит за releases/<version>.'
      ;;
  esac
  [ "$target" = "releases/$version" ] ||
    doctor_entrypoint_integrity_fail 'current содержит extra path.'

  release="$runtime/$target"
  [ -d "$release" ] && [ ! -L "$release" ] ||
    doctor_entrypoint_integrity_fail \
      'release отсутствует или является symlink.'
  release_physical="$(/bin/realpath "$release" 2>/dev/null)" ||
    doctor_entrypoint_integrity_fail 'release нельзя канонизировать.'
  [ "$SCRIPT_DIR" = "$release_physical" ] ||
    doctor_entrypoint_integrity_fail \
      'doctor запущен не из active release.'
  [ -f "$release/install.sh" ] && [ ! -L "$release/install.sh" ] ||
    doctor_entrypoint_integrity_fail 'install.sh отсутствует или небезопасен.'

  archive_sha="$(doctor_entrypoint_sha_marker \
    "$release/.bundle-sha256")" ||
    doctor_entrypoint_integrity_fail \
      '.bundle-sha256 отсутствует или malformed.'
  [ -n "$archive_sha" ] ||
    doctor_entrypoint_integrity_fail '.bundle-sha256 пуст.'
  expected_tree="$(doctor_entrypoint_sha_marker \
    "$release/.bundle-tree-sha256")" ||
    doctor_entrypoint_integrity_fail \
      '.bundle-tree-sha256 отсутствует или malformed.'
  actual_tree="$(doctor_entrypoint_release_tree_sha256 "$release")" ||
    doctor_entrypoint_integrity_fail \
      'release tree нельзя безопасно проверить.'
  [ "$actual_tree" = "$expected_tree" ] ||
    doctor_entrypoint_integrity_fail 'release tree fingerprint не совпал.'
}

if [ "$VIBE_MAC_DOCTOR_BUILD_KIND" = release ]; then
  doctor_entrypoint_verify_active_release
fi

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

REPAIR=0
ISSUES=0
BLOCKER=0
REPAIR_MODE_ROOT=0
REPAIR_STALE_LOCK=0
REPAIR_ZPROFILE_BLOCK=0
REPAIR_ZSHRC_BLOCK=0
REPAIR_ZPROFILE_CONTENT=
REPAIR_ZSHRC_CONTENT=

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
  schema="$(json_extract_typed \
    "$file" schema_version integer 2>/dev/null)" || {
    record_blocker "$label schema_version отсутствует или имеет неверный тип."
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

doctor_expected_homebrew_prefix() {
  if is_test_mode &&
    [ -n "${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" ]; then
    case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
      /*)
        case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
          *$'\n'*|*$'\r'*|*$'\t'*|*"'"*) return 2 ;;
        esac
        printf '%s\n' "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX"
        return 0
        ;;
      *)
        return 2
        ;;
    esac
  fi
  expected_homebrew_prefix
}

diagnose_homebrew_and_commands() {
  local expected bin name resolved trusted status
  expected="$(doctor_expected_homebrew_prefix)" || {
    record_blocker "Не удалось определить expected Homebrew prefix."
    return 0
  }
  bin="$expected/bin"

  if [ ! -d "$expected" ] || [ -L "$expected" ]; then
    record_issue "Expected Homebrew prefix отсутствует или небезопасен: $expected."
    return 0
  fi
  if [ ! -d "$bin" ] || [ -L "$bin" ]; then
    record_issue "Expected Homebrew bin отсутствует или небезопасен: $bin."
    return 0
  fi

  case ":${PATH:-}:" in
    *":$bin:"*) ;;
    *) record_issue "Homebrew bin отсутствует в PATH: $bin." ;;
  esac

  for name in brew git gh starship rg fd fzf bat eza jq tree zoxide mise uv; do
    status=0
    trusted="$(homebrew_executable_in_prefix "$expected" "$name" 2>/dev/null)" ||
      status="$?"
    case "$status" in
      0) ;;
      1)
        record_issue "Обязательный executable $name не найден в expected Homebrew prefix."
        continue
        ;;
      *)
        record_blocker "Executable $name в expected Homebrew prefix не прошёл canonical containment."
        continue
        ;;
    esac
    resolved="$(command -v "$name" 2>/dev/null || true)"
    if [ -z "$resolved" ]; then
      record_issue "Обязательный executable $name не найден."
      continue
    fi
    if [ "$resolved" != "$bin/$name" ]; then
      record_issue "$name разрешается вне expected Homebrew bin: $resolved."
      continue
    fi
    [ -n "$trusted" ] ||
      record_blocker "Executable $name не удалось канонизировать."
  done
}

zprofile_managed_content() {
  local prefix
  prefix="$(doctor_expected_homebrew_prefix)" || return 2
  shell_zprofile_managed_content_for_prefix "$prefix"
}

zshrc_activation_content() {
  local prefix
  prefix="$(doctor_expected_homebrew_prefix)" || return 2
  shell_zshrc_activation_content_for_prefix "$prefix"
}

zshrc_managed_content() {
  local prefix
  prefix="$(doctor_expected_homebrew_prefix)" || return 2
  shell_zshrc_managed_content_for_prefix "$prefix"
}

managed_block_status() {
  local target block_id expected_one expected_two actual
  local begin end begin_count end_count
  target="$1"
  block_id="$2"
  expected_one="$3"
  expected_two="$4"
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 1
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    record_blocker "managed block $block_id имеет небезопасный target."
    return 2
  fi
  begin_count="$(/usr/bin/grep -Fxc "$begin" "$target" || true)"
  end_count="$(/usr/bin/grep -Fxc "$end" "$target" || true)"
  if [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
    return 1
  fi
  if [ "$begin_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    record_blocker "managed block $block_id malformed."
    return 2
  fi
  actual="$(managed_block_sha "$target" "$block_id" 2>/dev/null)" || {
    record_blocker "managed block $block_id malformed."
    return 2
  }
  if [ "$actual" = "$expected_one" ] ||
    { [ -n "$expected_two" ] && [ "$actual" = "$expected_two" ]; }; then
    return 0
  fi
  return 3
}

schedule_managed_block_repair() {
  local id expected_one content_one expected_two content_two
  local owned kind block_id applied
  id="$1"
  expected_one="$2"
  content_one="$3"
  expected_two="$4"
  content_two="$5"
  owned="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned" 2>/dev/null || true)"
  kind="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.kind" 2>/dev/null || true)"
  block_id="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.block_id" 2>/dev/null || true)"
  applied="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.applied_sha" 2>/dev/null || true)"
  [ "$owned" = true ] && [ "$kind" = managed_block ] &&
    [ "$block_id" = "$id" ] || return 0

  if [ "$applied" = "$expected_one" ]; then
    case "$id" in
      zprofile)
        REPAIR_ZPROFILE_BLOCK=1
        REPAIR_ZPROFILE_CONTENT="$content_one"
        ;;
      zshrc)
        REPAIR_ZSHRC_BLOCK=1
        REPAIR_ZSHRC_CONTENT="$content_one"
        ;;
    esac
  elif [ -n "$expected_two" ] && [ "$applied" = "$expected_two" ]; then
    [ "$id" = zshrc ] || return 0
    REPAIR_ZSHRC_BLOCK=1
    REPAIR_ZSHRC_CONTENT="$content_two"
  fi
}

inspect_required_managed_blocks() {
  local zprofile_content zprofile_sha zshrc_content zshrc_sha
  local zshrc_activation zshrc_activation_sha ghostty_content ghostty_sha
  local zshrc_allowed_sha zshrc_allowed_content status
  zprofile_content="$(zprofile_managed_content)"
  zprofile_sha="$(sha256_text "$zprofile_content")"
  zshrc_content="$(zshrc_managed_content)"
  zshrc_sha="$(sha256_text "$zshrc_content")"
  zshrc_activation="$(zshrc_activation_content)"
  zshrc_activation_sha="$(sha256_text "$zshrc_activation")"
  zshrc_allowed_sha=
  zshrc_allowed_content=
  if zshrc_has_external_omz_source "$HOME/.zshrc" zshrc; then
    zshrc_allowed_sha="$zshrc_activation_sha"
    zshrc_allowed_content="$zshrc_activation"
  fi
  ghostty_content="$(/bin/cat "$VIBE_MAC_ROOT/config/ghostty.config")" || {
    record_blocker "Template Ghostty недоступен."
    return 0
  }
  ghostty_sha="$(sha256_text "$ghostty_content")"

  status=0
  managed_block_status \
    "$HOME/.zprofile" zprofile "$zprofile_sha" "" || status=$?
  case "$status" in
    1)
      record_issue "Обязательный managed block zprofile отсутствует."
      schedule_managed_block_repair \
        zprofile "$zprofile_sha" "$zprofile_content" "" ""
      ;;
    3) record_issue "Обязательный managed block zprofile изменён." ;;
  esac

  status=0
  managed_block_status \
    "$HOME/.zshrc" zshrc "$zshrc_sha" "$zshrc_allowed_sha" ||
    status=$?
  case "$status" in
    1)
      record_issue "Обязательный managed block zshrc отсутствует."
      schedule_managed_block_repair \
        zshrc "$zshrc_sha" "$zshrc_content" \
        "$zshrc_allowed_sha" "$zshrc_allowed_content"
      ;;
    3) record_issue "Обязательный managed block zshrc изменён." ;;
  esac

  status=0
  managed_block_status \
    "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
    ghostty "$ghostty_sha" "" || status=$?
  case "$status" in
    1) record_issue "Обязательный managed block ghostty отсутствует." ;;
    3) record_issue "Обязательный managed block ghostty изменён." ;;
  esac
}

inspect_required_shell_files() {
  local id target owned expected actual
  if [ ! -d "$HOME/.oh-my-zsh" ] || [ -L "$HOME/.oh-my-zsh" ]; then
    record_issue "Oh My Zsh directory отсутствует или небезопасен."
  elif [ ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] ||
    [ -L "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
    record_issue "Oh My Zsh entrypoint отсутствует или небезопасен."
  fi
  for id in aliases starship; do
    case "$id" in
      aliases) target="$HOME/.config/vibe-mac/aliases.zsh" ;;
      starship) target="$HOME/.config/starship.toml" ;;
    esac
    if [ ! -f "$target" ] || [ -L "$target" ]; then
      record_issue "Обязательный shell file $id отсутствует или небезопасен."
      continue
    fi
    if [ "$id" = aliases ] || [ "$id" = starship ]; then
      owned="$(json_extract_raw \
        "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned" 2>/dev/null || true)"
      if [ "$owned" = true ]; then
        case "$id" in
          aliases) expected="$(sha256_file \
            "$VIBE_MAC_ROOT/config/aliases.zsh")" ;;
          starship) expected="$(sha256_file \
            "$VIBE_MAC_ROOT/config/starship.toml")" ;;
        esac || {
          record_blocker "Template $id недоступен."
          continue
        }
        actual="$(sha256_file "$target")" || {
          record_blocker "Owned aliases нельзя хэшировать."
          continue
        }
        if [ "$actual" != "$expected" ]; then
          record_issue "Owned $id не совпадает с exact template."
        fi
      fi
    fi
  done
}

inspect_owned_omz_tree() {
  local owned expected actual
  owned="$(manifest_typed_value \
    components.oh_my_zsh.owned bool)" || {
    record_blocker "Oh My Zsh ownership имеет неверный тип."
    return 0
  }
  case "$owned" in
    false) return 0 ;;
    true) ;;
    *)
      record_blocker "Oh My Zsh ownership имеет неверный тип."
      return 0
      ;;
  esac
  expected="$(manifest_typed_value \
    components.oh_my_zsh.tree_sha256 string)" || {
    record_blocker "Oh My Zsh tree SHA имеет неверный тип."
    return 0
  }
  if ! validate_sha256_or_empty "$expected" || [ -z "$expected" ]; then
    record_blocker "Oh My Zsh tree SHA отсутствует или malformed."
    return 0
  fi
  actual="$(tree_sha256 "$HOME/.oh-my-zsh" 2>/dev/null)" || {
    record_issue "Owned Oh My Zsh tree отсутствует или небезопасен."
    return 0
  }
  if [ "$actual" != "$expected" ]; then
    record_issue "Oh My Zsh изменён после установки."
  fi
}

manifest_value() {
  json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "$1"
}

manifest_typed_value() {
  json_extract_typed "$VIBE_MAC_MANIFEST_FILE" "$1" "$2" 2>/dev/null
}

valid_release_version() {
  case "$1" in
    [A-Za-z0-9]*)
      case "$1" in *[!A-Za-z0-9._-]*|*..*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
}

validate_release_integrity() {
  local owned version path path_kind archive_sha tree_sha slot field
  local current_target actual_current release archive_marker tree_marker
  local actual_tree id expected_path launcher_path_kind launcher_path
  local launcher_owned expected_sha target actual_sha present
  local link_path_kind link_path link_owned

  if ! manifest_typed_value releases dictionary >/dev/null; then
    record_blocker "Manifest releases должен быть dictionary."
    return 0
  fi
  for slot in current previous; do
    if ! manifest_typed_value "releases.$slot" dictionary >/dev/null; then
      record_blocker "Manifest releases.$slot должен быть dictionary."
      return 0
    fi
    for field in version path_kind path archive_sha256 tree_sha256; do
      if ! manifest_typed_value \
        "releases.$slot.$field" string >/dev/null; then
        record_blocker \
          "Manifest releases.$slot.$field имеет неверный тип."
        return 0
      fi
    done
    if ! manifest_typed_value "releases.$slot.owned" bool >/dev/null; then
      record_blocker "Manifest releases.$slot.owned имеет неверный тип."
      return 0
    fi
  done
  if ! manifest_typed_value current_link dictionary >/dev/null; then
    record_blocker "Manifest current_link должен быть dictionary."
    return 0
  fi
  for field in path_kind path target; do
    if ! manifest_typed_value "current_link.$field" string >/dev/null; then
      record_blocker "Manifest current_link.$field имеет неверный тип."
      return 0
    fi
  done
  if ! manifest_typed_value current_link.owned bool >/dev/null; then
    record_blocker "Manifest current_link.owned имеет неверный тип."
    return 0
  fi
  if ! manifest_typed_value launchers dictionary >/dev/null; then
    record_blocker "Manifest launchers должен быть dictionary."
    return 0
  fi
  for id in verify doctor uninstall; do
    if ! manifest_typed_value "launchers.$id" dictionary >/dev/null; then
      record_blocker "Manifest launcher $id должен быть dictionary."
      return 0
    fi
    for field in path_kind path sha256; do
      if ! manifest_typed_value \
        "launchers.$id.$field" string >/dev/null; then
        record_blocker "Manifest launcher $id $field имеет неверный тип."
        return 0
      fi
    done
    if ! manifest_typed_value "launchers.$id.owned" bool >/dev/null; then
      record_blocker "Manifest launcher $id owned имеет неверный тип."
      return 0
    fi
  done

  owned="$(manifest_typed_value releases.current.owned bool)" || {
    record_blocker "Manifest release ownership отсутствует."
    return 0
  }
  case "$owned" in
    false)
      present=0
      for target in \
        "$VIBE_MAC_RUNTIME_ROOT/current" \
        "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" \
        "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor" \
        "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-uninstall"; do
        if [ -e "$target" ] || [ -L "$target" ]; then
          present=1
        fi
      done
      if [ "$present" -ne 0 ]; then
        record_blocker "Runtime artifacts существуют без typed release ownership."
      fi
      return 0
      ;;
    true)
      ;;
    *)
      record_blocker "Manifest release ownership имеет неверный тип."
      return 0
      ;;
  esac

  version="$(manifest_typed_value releases.current.version string)" || {
    record_blocker "Manifest release version отсутствует."
    return 0
  }
  path_kind="$(manifest_typed_value releases.current.path_kind string)" || {
    record_blocker "Manifest release path_kind имеет неверный тип."
    return 0
  }
  path="$(manifest_typed_value releases.current.path string)" || {
    record_blocker "Manifest release path имеет неверный тип."
    return 0
  }
  archive_sha="$(manifest_typed_value \
    releases.current.archive_sha256 string)" || {
    record_blocker "Manifest release archive SHA имеет неверный тип."
    return 0
  }
  tree_sha="$(manifest_typed_value \
    releases.current.tree_sha256 string)" || {
    record_blocker "Manifest release tree SHA имеет неверный тип."
    return 0
  }
  if ! valid_release_version "$version" ||
    [ "$path_kind" != runtime_relative ] ||
    [ "$path" != "releases/$version" ] ||
    ! validate_sha256_or_empty "$archive_sha" ||
    [ -z "$archive_sha" ] ||
    ! validate_sha256_or_empty "$tree_sha" ||
    [ -z "$tree_sha" ]; then
    record_blocker "Manifest release metadata не прошла allowlist."
    return 0
  fi
  if ! validate_home_dir_path "$VIBE_MAC_RUNTIME_ROOT/$path"; then
    record_blocker "Manifest release path содержит небезопасный ancestor."
    return 0
  fi

  current_target="$(manifest_typed_value current_link.target string)" ||
    current_target=
  link_path_kind="$(manifest_typed_value current_link.path_kind string)" ||
    link_path_kind=
  link_path="$(manifest_typed_value current_link.path string)" || link_path=
  link_owned="$(manifest_typed_value current_link.owned bool)" || link_owned=
  if [ "$link_path_kind" != runtime_relative ] ||
    [ "$link_path" != current ] ||
    [ "$link_owned" != true ] ||
    [ "$current_target" != "$path" ]; then
    record_blocker "Typed current_link не совпадает с manifest release."
    return 0
  fi

  release="$VIBE_MAC_RUNTIME_ROOT/$path"
  if [ ! -d "$release" ] || [ -L "$release" ]; then
    record_blocker "Verified release directory отсутствует или небезопасен."
    return 0
  fi
  if [ ! -L "$VIBE_MAC_RUNTIME_ROOT/current" ]; then
    record_blocker "current не совпадает с manifest: ожидается symlink."
    return 0
  fi
  actual_current="$(/usr/bin/readlink "$VIBE_MAC_RUNTIME_ROOT/current" \
    2>/dev/null || true)"
  if [ "$actual_current" != "$path" ]; then
    record_blocker "current не совпадает с manifest release."
    return 0
  fi

  archive_marker="$release/.bundle-sha256"
  tree_marker="$release/.bundle-tree-sha256"
  if [ ! -f "$archive_marker" ] || [ -L "$archive_marker" ] ||
    [ "$(/bin/cat "$archive_marker" 2>/dev/null || true)" != "$archive_sha" ]; then
    record_blocker "Release archive marker не совпадает с manifest."
    return 0
  fi
  if [ ! -f "$tree_marker" ] || [ -L "$tree_marker" ] ||
    [ "$(/bin/cat "$tree_marker" 2>/dev/null || true)" != "$tree_sha" ]; then
    record_blocker "Release tree marker не совпадает с manifest."
    return 0
  fi
  actual_tree="$(release_tree_sha256 "$release" 2>/dev/null)" || {
    record_blocker "release tree нельзя безопасно хэшировать."
    return 0
  }
  if [ "$actual_tree" != "$tree_sha" ]; then
    record_blocker "release tree hash не совпадает с manifest."
    return 0
  fi

  for id in verify doctor uninstall; do
    expected_path="bin/vibe-mac-$id"
    launcher_path_kind="$(manifest_typed_value \
      "launchers.$id.path_kind" string)" || launcher_path_kind=
    launcher_path="$(manifest_typed_value \
      "launchers.$id.path" string)" || launcher_path=
    launcher_owned="$(manifest_typed_value \
      "launchers.$id.owned" bool)" || launcher_owned=
    expected_sha="$(manifest_typed_value \
      "launchers.$id.sha256" string)" || expected_sha=
    if [ "$launcher_path_kind" != runtime_relative ] ||
      [ "$launcher_path" != "$expected_path" ] ||
      [ "$launcher_owned" != true ] ||
      ! validate_sha256_or_empty "$expected_sha" ||
      [ -z "$expected_sha" ]; then
      record_blocker "Manifest launcher $id metadata не прошла allowlist."
      continue
    fi
    target="$VIBE_MAC_RUNTIME_ROOT/$launcher_path"
    if [ ! -f "$target" ] || [ -L "$target" ] || [ ! -x "$target" ]; then
      record_blocker "Runtime launcher $id отсутствует или небезопасен."
      continue
    fi
    actual_sha="$(sha256_file "$target" 2>/dev/null)" || {
      record_blocker "Runtime launcher $id нельзя хэшировать."
      continue
    }
    if [ "$actual_sha" != "$expected_sha" ]; then
      record_blocker "Runtime launcher $id hash не совпадает с manifest."
    fi
  done
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
  local manifest_ready manifest_schema runtime_paths_safe
  ISSUES=0
  BLOCKER=0
  REPAIR_MODE_ROOT=0
  REPAIR_STALE_LOCK=0
  REPAIR_ZPROFILE_BLOCK=0
  REPAIR_ZSHRC_BLOCK=0
  REPAIR_ZPROFILE_CONTENT=
  REPAIR_ZSHRC_CONTENT=

  runtime_paths_safe=1
  if ! validate_home_dir_path "$VIBE_MAC_STATE_DIR" ||
    ! validate_home_dir_path "$VIBE_MAC_RUNTIME_ROOT/releases" ||
    ! validate_home_dir_path "$VIBE_MAC_RUNTIME_ROOT/bin"; then
    record_blocker "Runtime/state/release path содержит небезопасный ancestor."
    runtime_paths_safe=0
  fi
  if [ "$runtime_paths_safe" -eq 1 ]; then
    validate_json_file "$VIBE_MAC_STATE_FILE" "$STATE_SCHEMA_VERSION" progress.json
    validate_json_file "$VIBE_MAC_MANIFEST_FILE" "$MANIFEST_SCHEMA_VERSION" manifest.json
    safe_current_target
    runtime_mode_check
  fi
  manifest_ready=0
  manifest_schema="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" schema_version integer 2>/dev/null || true)"
  if [ "$runtime_paths_safe" -eq 1 ] &&
    [ -f "$VIBE_MAC_MANIFEST_FILE" ] &&
    [ ! -L "$VIBE_MAC_MANIFEST_FILE" ] &&
    json_lint "$VIBE_MAC_MANIFEST_FILE" &&
    [ "$manifest_schema" = "$MANIFEST_SCHEMA_VERSION" ]; then
    manifest_ready=1
  fi
  if [ "$manifest_ready" -eq 1 ]; then
    validate_manifest_file_evidence
    validate_release_integrity
    inspect_manifest_targets
    inspect_owned_omz_tree
  fi
  diagnose_homebrew_and_commands
  inspect_required_managed_blocks
  inspect_required_shell_files
  if [ "$runtime_paths_safe" -eq 1 ]; then
    diagnose_lock
  fi

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
  if [ "$REPAIR_ZPROFILE_BLOCK" = 1 ]; then
    printf '  - восстановить exact owned managed block: %s\n' \
      "$HOME/.zprofile"
  fi
  if [ "$REPAIR_ZSHRC_BLOCK" = 1 ]; then
    printf '  - восстановить exact owned managed block: %s\n' \
      "$HOME/.zshrc"
  fi
  if [ "$REPAIR_MODE_ROOT" = 0 ] &&
    [ "$REPAIR_STALE_LOCK" = 0 ] &&
    [ "$REPAIR_ZPROFILE_BLOCK" = 0 ] &&
    [ "$REPAIR_ZSHRC_BLOCK" = 0 ]; then
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

repair_managed_block() {
  local id target content relative logical expected owned applied status
  id="$1"
  target="$2"
  content="$3"
  case "$id" in
    zprofile)
      relative=.zprofile
      logical=zprofile
      ;;
    zshrc)
      relative=.zshrc
      logical=zshrc
      ;;
    *)
      return 2
      ;;
  esac
  expected="$(sha256_text "$content")" || return 2
  manifest_validate_file_entry \
    "$id" "$relative" managed_block "$id" "$logical" || return 2
  owned="$(manifest_value "files.$id.owned")" || return 2
  applied="$(manifest_value "files.$id.applied_sha")" || return 2
  [ "$owned" = true ] && [ "$applied" = "$expected" ] || return 2
  status=0
  managed_block_status "$target" "$id" "$expected" "" || status=$?
  [ "$status" -eq 1 ] || return 2
  managed_block_upsert "$target" "$id" "$content" "$logical"
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
if [ "$REPAIR_MODE_ROOT" = 0 ] &&
  [ "$REPAIR_STALE_LOCK" = 0 ] &&
  [ "$REPAIR_ZPROFILE_BLOCK" = 0 ] &&
  [ "$REPAIR_ZSHRC_BLOCK" = 0 ]; then
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
if [ "$REPAIR_ZPROFILE_BLOCK" = 1 ]; then
  repair_managed_block \
    zprofile "$HOME/.zprofile" "$REPAIR_ZPROFILE_CONTENT" || {
    ui_fail "zprofile block не исправлен: повторная safety-проверка не прошла."
    exit 2
  }
fi
if [ "$REPAIR_ZSHRC_BLOCK" = 1 ]; then
  repair_managed_block zshrc "$HOME/.zshrc" "$REPAIR_ZSHRC_CONTENT" || {
    ui_fail "zshrc block не исправлен: повторная safety-проверка не прошла."
    exit 2
  }
fi

diagnose
if [ "$BLOCKER" -ne 0 ]; then
  exit 2
fi
[ "$ISSUES" -eq 0 ]
