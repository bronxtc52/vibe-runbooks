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

APPLY=0
CONFLICTS=0
RELEASE_STATE=none
RELEASE_VERSION=
RELEASE_PATH=
UNINSTALL_TEMP=

usage() {
  printf '%s\n' \
    "Запуск: /bin/bash ./uninstall.sh [--dry-run|--apply]" \
    "Без флага выполняется только план. Apply требует typed UNINSTALL."
}

cleanup_uninstall_temp() {
  local exit_code prefix
  exit_code="$?"
  if [ -n "$UNINSTALL_TEMP" ]; then
    prefix="${TMPDIR:-/tmp}/vibe-mac-uninstall."
    case "$UNINSTALL_TEMP" in
      "$prefix"*)
        if [ -d "$UNINSTALL_TEMP" ] && [ ! -L "$UNINSTALL_TEMP" ]; then
          /usr/bin/find "$UNINSTALL_TEMP" -depth -delete
        fi
        ;;
    esac
  fi
  return "$exit_code"
}

formulae() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_UNINSTALL_FORMULAE:-}" ]; then
    printf '%s\n' "$VIBE_MAC_TEST_UNINSTALL_FORMULAE" | /usr/bin/tr ' ' '\n'
    return
  fi
  printf '%s\n' \
    git gh starship ripgrep fd fzf bat eza jq tree zoxide mise uv
}

casks() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_UNINSTALL_CASKS:-}" ]; then
    printf '%s\n' "$VIBE_MAC_TEST_UNINSTALL_CASKS" | /usr/bin/tr ' ' '\n'
    return
  fi
  printf '%s\n' \
    ghostty font-jetbrains-mono-nerd-font claude-code codex cursor cursor-cli \
    zed raycast visual-studio-code
}

defaults_tool() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_DEFAULTS_BIN:?test defaults не задан}"
  else
    printf '%s\n' /usr/bin/defaults
  fi
}

killall_tool() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_KILLALL_BIN:?test killall не задан}"
  else
    printf '%s\n' /usr/bin/killall
  fi
}

manifest_value() {
  json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "$1" 2>/dev/null
}

validate_manifest() {
  local schema
  if [ ! -f "$VIBE_MAC_MANIFEST_FILE" ] || [ -L "$VIBE_MAC_MANIFEST_FILE" ]; then
    ui_fail "Manifest отсутствует или является symlink; удаление заблокировано."
    return 2
  fi
  if ! json_lint "$VIBE_MAC_MANIFEST_FILE"; then
    ui_fail "Manifest повреждён; удаление заблокировано."
    return 2
  fi
  schema="$(manifest_value schema_version)" || {
    ui_fail "Manifest не содержит schema_version."
    return 2
  }
  if [ "$schema" != "$MANIFEST_SCHEMA_VERSION" ]; then
    ui_fail "Неизвестная manifest schema: $schema."
    return 2
  fi
}

validate_file_entry() {
  manifest_validate_file_entry "$1" "$2" "$3" "$4" "$5"
}

validate_file_entries() {
  if ! validate_file_entry \
    zprofile .zprofile managed_block zprofile zprofile ||
    ! validate_file_entry zshrc .zshrc managed_block zshrc zshrc ||
    ! validate_file_entry ghostty \
      "Library/Application Support/com.mitchellh.ghostty/config" \
      managed_block ghostty ghostty-config ||
    ! validate_file_entry aliases \
      .config/vibe-mac/aliases.zsh owned_file "" aliases-zsh ||
    ! validate_file_entry starship \
      .config/starship.toml owned_file "" starship-toml ||
    ! validate_file_entry mise-global \
      .config/mise/config.toml owned_file "" mise-global; then
    ui_fail "Manifest содержит небезопасную file ownership запись."
    return 2
  fi
}

validate_git_default_entry() {
  local id expected_key expected_value key value created
  id="$1"
  expected_key="$2"
  expected_value="$3"
  if ! manifest_value "git_defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  key="$(manifest_value "git_defaults.$id.key")" || return 2
  value="$(manifest_value "git_defaults.$id.applied_value")" || return 2
  created="$(manifest_value "git_defaults.$id.created")" || return 2
  [ "$key" = "$expected_key" ] &&
    [ "$value" = "$expected_value" ] &&
    [ "$created" = true ]
}

validate_git_defaults() {
  if ! validate_git_default_entry \
    init-default-branch init.defaultBranch main ||
    ! validate_git_default_entry pull-rebase pull.rebase true ||
    ! validate_git_default_entry \
      push-auto-upstream push.autoSetupRemote true; then
    ui_fail "Manifest содержит небезопасную Git defaults запись."
    return 2
  fi
}

validate_omz_entry() {
  local owned preexisting tree
  owned="$(manifest_value components.oh_my_zsh.owned)" || return 2
  preexisting="$(manifest_value components.oh_my_zsh.preexisting)" || return 2
  tree="$(manifest_value components.oh_my_zsh.tree_sha256)" || return 2
  case "$owned:$preexisting" in
    false:false|false:true)
      [ -z "$tree" ] || validate_sha256_or_empty "$tree"
      ;;
    true:false)
      validate_sha256_or_empty "$tree" && [ -n "$tree" ]
      ;;
    *)
      return 2
      ;;
  esac
}

validate_release_entry() {
  local owned path_kind archive_sha tree_sha current_target
  local launcher_id expected_path launcher_path_kind launcher_path
  local expected_sha actual_sha present missing target
  local actual_current archive_marker_value tree_marker_value actual_tree
  owned="$(manifest_value releases.current.owned)" || return 2
  case "$owned" in
    false)
      RELEASE_STATE=none
      return 0
      ;;
    true)
      ;;
    *)
      return 2
      ;;
  esac
  RELEASE_VERSION="$(manifest_value releases.current.version)" || return 2
  path_kind="$(manifest_value releases.current.path_kind)" || return 2
  RELEASE_PATH="$(manifest_value releases.current.path)" || return 2
  archive_sha="$(manifest_value releases.current.archive_sha256)" || return 2
  tree_sha="$(manifest_value releases.current.tree_sha256)" || return 2
  case "$RELEASE_VERSION" in
    [A-Za-z0-9]*)
      case "$RELEASE_VERSION" in *[!A-Za-z0-9._-]*|*..*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  [ "$path_kind" = runtime_relative ] || return 2
  [ "$RELEASE_PATH" = "releases/$RELEASE_VERSION" ] || return 2
  validate_sha256_or_empty "$archive_sha" && [ -n "$archive_sha" ] || return 2
  validate_sha256_or_empty "$tree_sha" && [ -n "$tree_sha" ] || return 2
  [ "$(manifest_value current_link.path_kind)" = runtime_relative ] ||
    return 2
  [ "$(manifest_value current_link.path)" = current ] || return 2
  current_target="$(manifest_value current_link.target)" || return 2
  [ "$current_target" = "$RELEASE_PATH" ] || return 2
  [ "$(manifest_value current_link.owned)" = true ] || return 2

  present=0
  missing=0
  for target in \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" \
    "$VIBE_MAC_RUNTIME_ROOT/current" \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor" \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-uninstall"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
      present=$((present + 1))
    else
      missing=$((missing + 1))
    fi
  done
  if [ "$present" -eq 0 ]; then
    RELEASE_STATE=removed
    return 0
  fi
  [ "$missing" -eq 0 ] || return 2

  [ -d "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" ] || return 2
  [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ] || return 2
  actual_current="$(/usr/bin/readlink "$VIBE_MAC_RUNTIME_ROOT/current")" ||
    return 2
  [ "$actual_current" = "$RELEASE_PATH" ] || return 2
  [ -f "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-sha256" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-sha256" ] ||
    return 2
  archive_marker_value="$(/bin/cat \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-sha256")" || return 2
  [ "$archive_marker_value" = "$archive_sha" ] || return 2
  [ -f "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-tree-sha256" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-tree-sha256" ] ||
    return 2
  tree_marker_value="$(/bin/cat \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-tree-sha256")" ||
    return 2
  [ "$tree_marker_value" = "$tree_sha" ] || return 2
  actual_tree="$(release_tree_sha256 \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH")" || return 2
  [ "$actual_tree" = "$tree_sha" ] || return 2

  for launcher_id in verify doctor uninstall; do
    expected_path="bin/vibe-mac-$launcher_id"
    launcher_path_kind="$(manifest_value \
      "launchers.$launcher_id.path_kind")" || return 2
    launcher_path="$(manifest_value "launchers.$launcher_id.path")" ||
      return 2
    expected_sha="$(manifest_value "launchers.$launcher_id.sha256")" ||
      return 2
    [ "$launcher_path_kind" = runtime_relative ] || return 2
    [ "$launcher_path" = "$expected_path" ] || return 2
    [ "$(manifest_value "launchers.$launcher_id.owned")" = true ] ||
      return 2
    validate_sha256_or_empty "$expected_sha" &&
      [ -n "$expected_sha" ] || return 2
    target="$VIBE_MAC_RUNTIME_ROOT/$launcher_path"
    [ -f "$target" ] && [ ! -L "$target" ] || return 2
    actual_sha="$(sha256_file "$target")" || return 2
    [ "$actual_sha" = "$expected_sha" ] || return 2
  done
  RELEASE_STATE=ready
}

package_owned() {
  local kind name owned preexisting owner
  kind="$1"
  name="$2"
  owned="$(manifest_value "packages.$kind.$name.owned" 2>/dev/null || true)"
  preexisting="$(manifest_value \
    "packages.$kind.$name.preexisting" 2>/dev/null || true)"
  owner="$(manifest_value "packages.$kind.$name.owner" 2>/dev/null || true)"
  [ "$owned" = true ] &&
    [ "$preexisting" = false ] &&
    [ "$owner" = vibe-mac ]
}

file_entry_owned() {
  [ "$(manifest_value "files.$1.owned" 2>/dev/null || true)" = true ]
}

show_plan() {
  local name found
  found=0
  printf '%s\n' "План удаления (пока без изменений):"
  for name in $(formulae); do
    if package_owned formulae "$name"; then
      printf '  - Homebrew formula: %s\n' "$name"
      found=1
    fi
  done
  for name in $(casks); do
    if package_owned casks "$name"; then
      printf '  - Homebrew cask: %s (без zap)\n' "$name"
      found=1
    fi
  done
  for name in zprofile zshrc ghostty aliases starship mise-global; do
    if file_entry_owned "$name"; then
      printf '  - managed file entry: %s\n' "$name"
      found=1
    fi
  done
  for name in dock_autohide finder_extensions; do
    if manifest_value "defaults.$name" >/dev/null 2>&1; then
      printf '  - восстановить macOS default: %s\n' "$name"
      found=1
    fi
  done
  for name in init-default-branch pull-rebase push-auto-upstream; do
    if manifest_value "git_defaults.$name" >/dev/null 2>&1; then
      printf '  - удалить созданный Git default: %s\n' "$name"
      found=1
    fi
  done
  if [ "$(manifest_value components.oh_my_zsh.owned 2>/dev/null || true)" = true ]; then
    printf '%s\n' "  - owned tree: .oh-my-zsh"
    found=1
  fi
  case "$RELEASE_STATE" in
    ready)
      printf '  - verified release bundle: %s\n' "$RELEASE_PATH"
      found=1
      ;;
    removed)
      printf '  - release bundle уже удалён: %s\n' "$RELEASE_PATH"
      ;;
  esac
  if [ "$found" = 0 ]; then
    printf '%s\n' "  - owned-компонентов в manifest нет"
  fi
  printf '%s\n' \
    "Сохраняются: Homebrew, Xcode CLT, workspace, аккаунты, credentials," \
    "логи, state и $VIBE_MAC_BACKUP_ROOT."
}

uninstall_formula() {
  local name dependents expected current line
  name="$1"
  if ! brew list --formula "$name" >/dev/null 2>&1; then
    return 0
  fi
  expected="$(manifest_value "packages.formulae.$name.version_after")" ||
    return 2
  line="$(brew list --formula --versions "$name" 2>/dev/null)" || {
    ui_warn "Не удалось проверить version formula $name; оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  }
  current="${line#"$name" }"
  if [ -z "$current" ] || [ "$current" != "$expected" ]; then
    ui_warn "Formula $name имеет version drift; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  dependents="$(brew uses --installed "$name" 2>/dev/null)" || {
    ui_warn "Не удалось проверить dependents formula $name; оставляю."
    return 0
  }
  if [ -n "$dependents" ]; then
    ui_warn "Formula $name нужна другим пакетам; оставляю."
    return 0
  fi
  brew uninstall "$name"
}

uninstall_cask() {
  local name expected current line
  name="$1"
  if brew list --cask "$name" >/dev/null 2>&1; then
    expected="$(manifest_value "packages.casks.$name.version_after")" ||
      return 2
    line="$(brew list --cask --versions "$name" 2>/dev/null)" || {
      ui_warn "Не удалось проверить version cask $name; оставляю."
      CONFLICTS=$((CONFLICTS + 1))
      return 0
    }
    current="${line#"$name" }"
    if [ -z "$current" ] || [ "$current" != "$expected" ]; then
      ui_warn "Cask $name имеет version drift; конфликт, оставляю."
      CONFLICTS=$((CONFLICTS + 1))
      return 0
    fi
    brew uninstall --cask "$name"
  fi
}

block_content_sha() {
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
  ' "$target" | sha256_stream
}

sha256_stream() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  elif have sha256sum; then
    sha256sum | awk '{print $1}'
  else
    return 2
  fi
}

remove_managed_block() {
  local id target block_id expected actual begin end parent temp
  id="$1"
  target="$2"
  block_id="$3"
  expected="$(manifest_value "files.$id.applied_sha")" || return 2
  if [ ! -e "$target" ]; then
    return 0
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    ui_warn "Файл $target стал небезопасным; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  actual="$(block_content_sha "$target" "$block_id" 2>/dev/null)" || {
    ui_warn "Managed block $id изменён или malformed; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  }
  if [ "$actual" != "$expected" ]; then
    ui_warn "Managed block $id изменён; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"
  parent="${target%/*}"
  temp="$(/usr/bin/mktemp "$parent/.vibe-mac-uninstall.XXXXXX")"
  if ! /usr/bin/awk -v begin="$begin" -v end="$end" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    !inside { print }
  ' "$target" >"$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod "$(file_mode "$target")" "$temp"
  /bin/mv -f "$temp" "$target"
}

remove_owned_file() {
  local id target expected actual
  id="$1"
  target="$2"
  expected="$(manifest_value "files.$id.applied_sha")" || return 2
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    ui_warn "Owned file $id стал небезопасным; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  actual="$(sha256_file "$target")" || return 2
  if [ "$actual" != "$expected" ]; then
    ui_warn "Owned file $id изменён; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  /bin/unlink "$target"
}

remove_owned_omz() {
  local target expected actual
  if [ "$(manifest_value components.oh_my_zsh.owned)" != true ]; then
    return 0
  fi
  target="$HOME/.oh-my-zsh"
  expected="$(manifest_value components.oh_my_zsh.tree_sha256)"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ -L "$target" ] || [ ! -d "$target" ]; then
    ui_warn "Owned Oh My Zsh path стал небезопасным; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  actual="$(tree_sha256 "$target" 2>/dev/null)" || {
    ui_warn "Oh My Zsh tree нельзя безопасно проверить; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  }
  if [ "$actual" != "$expected" ]; then
    ui_warn "Oh My Zsh изменён; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  /usr/bin/find "$target" -depth -delete
}

prepare_uninstall_self_copy() {
  local source_sha copy_sha
  UNINSTALL_TEMP="$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/vibe-mac-uninstall.XXXXXX")"
  /bin/chmod 0700 "$UNINSTALL_TEMP"
  /bin/cp "$0" "$UNINSTALL_TEMP/uninstall.sh"
  /bin/chmod 0700 "$UNINSTALL_TEMP/uninstall.sh"
  source_sha="$(sha256_file "$0")"
  copy_sha="$(sha256_file "$UNINSTALL_TEMP/uninstall.sh")"
  [ "$source_sha" = "$copy_sha" ] || return 2
}

remove_release_bundle() {
  local launcher
  [ "$RELEASE_STATE" = ready ] || return 0
  validate_release_entry || return 2
  [ "$RELEASE_STATE" = ready ] || return 2
  for launcher in verify doctor uninstall; do
    /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher"
  done
  /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  /usr/bin/find \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" -depth -delete
  RELEASE_STATE=removed
}

restore_default() {
  local id domain key original_exists original_value applied_value
  local tool restarter current
  id="$1"
  if ! manifest_value "defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  domain="$(manifest_value "defaults.$id.domain")" || return 2
  key="$(manifest_value "defaults.$id.key")" || return 2
  original_exists="$(manifest_value "defaults.$id.original_exists")" || return 2
  original_value="$(manifest_value "defaults.$id.original_value")" || return 2
  applied_value="$(manifest_value "defaults.$id.applied_value")" || return 2
  case "$id:$domain:$key" in
    dock_autohide:com.apple.dock:autohide) ;;
    finder_extensions:NSGlobalDomain:AppleShowAllExtensions) ;;
    *) return 2 ;;
  esac
  case "$original_exists:$original_value:$applied_value" in
    true:true:true|true:false:true|false:false:true) ;;
    *) return 2 ;;
  esac
  tool="$(defaults_tool)"
  restarter="$(killall_tool)"
  current="$("$tool" read "$domain" "$key" 2>/dev/null || true)"
  case "$current" in 1|true|TRUE|YES|yes) ;; *)
    ui_warn "Default $id уже изменён после установки; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  esac
  if [ "$original_exists" = true ]; then
    "$tool" write "$domain" "$key" -bool "$original_value"
  else
    "$tool" delete "$domain" "$key"
  fi
  case "$id" in
    dock_autohide) "$restarter" Dock >/dev/null 2>&1 || true ;;
    finder_extensions) "$restarter" Finder >/dev/null 2>&1 || true ;;
  esac
}

remove_git_default() {
  local id key expected current
  id="$1"
  if ! manifest_value "git_defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  key="$(manifest_value "git_defaults.$id.key")" || return 2
  expected="$(manifest_value "git_defaults.$id.applied_value")" || return 2
  current="$(git config --global --get "$key" 2>/dev/null || true)"
  if [ -z "$current" ]; then
    return 0
  fi
  if [ "$current" != "$expected" ]; then
    ui_warn "Git default $key изменён пользователем; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  git config --global --unset "$key"
}

apply_files() {
  if file_entry_owned zprofile; then
    remove_managed_block zprofile "$HOME/.zprofile" zprofile
  fi
  if file_entry_owned zshrc; then
    remove_managed_block zshrc "$HOME/.zshrc" zshrc
  fi
  if file_entry_owned ghostty; then
    remove_managed_block ghostty \
      "$HOME/Library/Application Support/com.mitchellh.ghostty/config" ghostty
  fi
  if file_entry_owned aliases; then
    remove_owned_file aliases "$HOME/.config/vibe-mac/aliases.zsh"
  fi
  if file_entry_owned starship; then
    remove_owned_file starship "$HOME/.config/starship.toml"
  fi
  if file_entry_owned mise-global; then
    remove_owned_file mise-global "$HOME/.config/mise/config.toml"
  fi
}

apply_uninstall() {
  local name
  if have brew; then
    for name in $(formulae); do
      if package_owned formulae "$name"; then
        uninstall_formula "$name"
      fi
    done
    for name in $(casks); do
      if package_owned casks "$name"; then
        uninstall_cask "$name"
      fi
    done
  else
    ui_warn "Homebrew недоступен; owned packages оставлены."
  fi
  apply_files
  remove_owned_omz
  restore_default dock_autohide
  restore_default finder_extensions
  if have git; then
    remove_git_default init-default-branch
    remove_git_default pull-rebase
    remove_git_default push-auto-upstream
  fi
  remove_release_bundle
}

case "${1:-}" in
  "")
    ;;
  --dry-run)
    ;;
  --apply)
    APPLY=1
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

validate_manifest
validate_file_entries
validate_git_defaults
validate_omz_entry
if ! validate_release_entry; then
  ui_fail "Manifest/runtime release ownership не прошёл integrity-проверку."
  exit 2
fi
show_plan

if [ "$APPLY" = 0 ]; then
  exit 0
fi
if ! ui_confirm_typed \
  "Удаление затронет только owned-цели из плана." \
  UNINSTALL; then
  ui_warn "Удаление отменено; точное слово UNINSTALL не введено."
  exit 1
fi

trap cleanup_uninstall_temp EXIT
trap 'exit 130' INT TERM HUP
prepare_uninstall_self_copy || {
  ui_fail "Self-copy uninstall не прошёл SHA-проверку."
  exit 2
}
apply_uninstall
printf '%s\n' \
  "Удаление owned-компонентов завершено." \
  "Workspace, аккаунты, credentials, state, logs и backups сохранены."
if [ "$CONFLICTS" -gt 0 ]; then
  ui_warn "Найдено конфликтов: $CONFLICTS; изменённые файлы сохранены."
  exit 1
fi
