#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VIBE_MAC_ROOT="${VIBE_MAC_ROOT:-$(cd "$STEP_DIR/.." && pwd -P)}"
export VIBE_MAC_ROOT

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"

OMZ_TEMP_DIR=

cleanup_omz_temp() {
  if [ -n "$OMZ_TEMP_DIR" ] && [ -d "$OMZ_TEMP_DIR" ]; then
    remove_temp_tree "$OMZ_TEMP_DIR" || true
  fi
  OMZ_TEMP_DIR=
}

install_oh_my_zsh() {
  local archive source_dir url
  if [ -L "$HOME/.oh-my-zsh" ]; then
    ui_fail "$HOME/.oh-my-zsh не может быть symlink."
    return 2
  fi
  if [ -d "$HOME/.oh-my-zsh" ]; then
    return 0
  fi
  if [ -e "$HOME/.oh-my-zsh" ]; then
    ui_fail "$HOME/.oh-my-zsh занят не каталогом."
    return 2
  fi

  if is_test_mode; then
    /bin/mkdir -p "$HOME/.oh-my-zsh"
    printf '%s\n' '# test Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
    printf '%s\n' "oh-my-zsh:install" >>"$VIBE_MAC_EVENT_LOG"
    return 0
  fi

  OMZ_TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vibe-mac.omz.XXXXXX")"
  /bin/chmod 0700 "$OMZ_TEMP_DIR"
  archive="$OMZ_TEMP_DIR/ohmyzsh.tar.gz"
  url="https://github.com/ohmyzsh/ohmyzsh/archive/$OH_MY_ZSH_COMMIT.tar.gz"
  safe_download "$url" "$archive" "$OH_MY_ZSH_ARCHIVE_SHA256"

  if ! /usr/bin/tar -tzf "$archive" | /usr/bin/awk \
    -v root="ohmyzsh-$OH_MY_ZSH_COMMIT/" '
      index($0, root) != 1 || $0 ~ /(^|\\/)\\.\\.(\\/|$)/ || $0 ~ /^\\// {
        bad = 1
      }
      END { exit bad }
    '; then
    ui_fail "Архив Oh My Zsh содержит неожиданные пути."
    return 2
  fi

  /usr/bin/tar -xzf "$archive" -C "$OMZ_TEMP_DIR"
  source_dir="$OMZ_TEMP_DIR/ohmyzsh-$OH_MY_ZSH_COMMIT"
  if [ ! -f "$source_dir/oh-my-zsh.sh" ] || [ -L "$source_dir" ]; then
    ui_fail "Архив Oh My Zsh не прошёл проверку структуры."
    return 2
  fi
  /bin/mv "$source_dir" "$HOME/.oh-my-zsh"
  cleanup_omz_temp
}

shell_ready() {
  [ -d "$HOME/.oh-my-zsh" ] &&
    [ ! -L "$HOME/.oh-my-zsh" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:zprofile >>>' "$HOME/.zprofile" &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:zshrc >>>' "$HOME/.zshrc" &&
    [ -f "$HOME/.config/vibe-mac/aliases.zsh" ] &&
    [ -f "$HOME/.config/starship.toml" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:ghostty >>>' \
      "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
}

zshrc_has_external_omz() {
  [ -f "$HOME/.zshrc" ] || return 1
  /usr/bin/awk '
    $0 == "# >>> vibe-mac managed:zshrc >>>" { inside = 1; next }
    $0 == "# <<< vibe-mac managed:zshrc <<<" { inside = 0; next }
    !inside { print }
  ' "$HOME/.zshrc" | /usr/bin/grep -F 'oh-my-zsh.sh' >/dev/null 2>&1
}

apply_shell() {
  local zprofile_block zshrc_block omz_block ghostty_content
  local ghostty_target aliases_target starship_target
  local omz_preexisting aliases_preexisting starship_preexisting
  local zprofile_file_preexisting zshrc_file_preexisting
  local ghostty_file_preexisting
  local zprofile_block_preexisting zshrc_block_preexisting
  local ghostty_block_preexisting omz_tree omz_json

  omz_preexisting=false
  aliases_preexisting=false
  starship_preexisting=false
  zprofile_block_preexisting=false
  zshrc_block_preexisting=false
  ghostty_block_preexisting=false
  zprofile_file_preexisting=false
  zshrc_file_preexisting=false
  ghostty_file_preexisting=false
  [ -d "$HOME/.oh-my-zsh" ] && omz_preexisting=true
  [ -e "$HOME/.config/vibe-mac/aliases.zsh" ] && aliases_preexisting=true
  [ -e "$HOME/.config/starship.toml" ] && starship_preexisting=true
  [ -e "$HOME/.zprofile" ] && zprofile_file_preexisting=true
  [ -e "$HOME/.zshrc" ] && zshrc_file_preexisting=true
  if [ -f "$HOME/.zprofile" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:zprofile >>>' \
      "$HOME/.zprofile"; then
    zprofile_block_preexisting=true
  fi
  if [ -f "$HOME/.zshrc" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:zshrc >>>' \
      "$HOME/.zshrc"; then
    zshrc_block_preexisting=true
  fi
  ghostty_target="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  [ -e "$ghostty_target" ] && ghostty_file_preexisting=true
  if [ -f "$ghostty_target" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:ghostty >>>' \
      "$ghostty_target"; then
    ghostty_block_preexisting=true
  fi

  install_oh_my_zsh

  aliases_target="$HOME/.config/vibe-mac/aliases.zsh"
  starship_target="$HOME/.config/starship.toml"
  if [ -e "$aliases_target" ] &&
    ! /usr/bin/cmp -s "$VIBE_MAC_ROOT/config/aliases.zsh" "$aliases_target"; then
    ui_fail "Путь $aliases_target уже занят другим содержимым."
    return 2
  fi
  install_file_if_absent \
    "$VIBE_MAC_ROOT/config/aliases.zsh" \
    "$aliases_target" \
    aliases-zsh
  install_file_if_absent \
    "$VIBE_MAC_ROOT/config/starship.toml" \
    "$starship_target" \
    starship-toml

  # shellcheck disable=SC2016
  zprofile_block='if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
export PATH="$HOME/.vibe-mac/bin:$HOME/.local/bin:$PATH"
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh --shims)"
fi'

  # shellcheck disable=SC2016
  zshrc_block='if [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]; then
  source "$HOME/.config/vibe-mac/aliases.zsh"
fi
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi
if command -v brew >/dev/null 2>&1 && [ -r "$(brew --prefix)/opt/fzf/shell/completion.zsh" ]; then
  source "$(brew --prefix)/opt/fzf/shell/completion.zsh"
fi
if command -v brew >/dev/null 2>&1 && [ -r "$(brew --prefix)/opt/fzf/shell/key-bindings.zsh" ]; then
  source "$(brew --prefix)/opt/fzf/shell/key-bindings.zsh"
fi
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi'

  if ! zshrc_has_external_omz; then
    # shellcheck disable=SC2016
    omz_block='export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""
plugins=(git)
if [ -r "$ZSH/oh-my-zsh.sh" ]; then
  source "$ZSH/oh-my-zsh.sh"
fi'
    zshrc_block="$omz_block
$zshrc_block"
  fi

  managed_block_upsert "$HOME/.zprofile" zprofile "$zprofile_block" zprofile
  managed_block_upsert "$HOME/.zshrc" zshrc "$zshrc_block" zshrc

  ghostty_content="$(/bin/cat "$VIBE_MAC_ROOT/config/ghostty.config")"
  managed_block_upsert "$ghostty_target" ghostty "$ghostty_content" ghostty-config

  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  if [ "$zprofile_block_preexisting" = false ]; then
    manifest_record_file \
      zprofile .zprofile managed_block zprofile "$zprofile_file_preexisting" true \
      "$(sha256_text "$zprofile_block")" zprofile
  fi
  if [ "$zshrc_block_preexisting" = false ]; then
    manifest_record_file \
      zshrc .zshrc managed_block zshrc "$zshrc_file_preexisting" true \
      "$(sha256_text "$zshrc_block")" zshrc
  fi
  if [ "$ghostty_block_preexisting" = false ]; then
    manifest_record_file \
      ghostty \
      "Library/Application Support/com.mitchellh.ghostty/config" \
      managed_block ghostty "$ghostty_file_preexisting" true \
      "$(sha256_text "$ghostty_content")" ghostty-config
  fi
  if [ "$aliases_preexisting" = false ]; then
    manifest_record_file \
      aliases .config/vibe-mac/aliases.zsh owned_file "" false true \
      "$(sha256_file "$aliases_target")" aliases-zsh
  fi
  if [ "$starship_preexisting" = false ]; then
    manifest_record_file \
      starship .config/starship.toml owned_file "" false true \
      "$(sha256_file "$starship_target")" starship-toml
  fi
  if [ "$omz_preexisting" = false ]; then
    omz_tree="$(tree_sha256 "$HOME/.oh-my-zsh")"
    omz_json="{\"preexisting\":false,\"owned\":true,\"version_before\":\"\",\"version_after\":\"$OH_MY_ZSH_COMMIT\",\"tree_sha256\":\"$omz_tree\"}"
  else
    omz_json='{"preexisting":true,"owned":false,"version_before":"external","version_after":"external","tree_sha256":""}'
  fi
  json_set_json_atomic \
    "$VIBE_MAC_MANIFEST_FILE" components.oh_my_zsh "$omz_json"
}

trap cleanup_omz_temp EXIT
trap 'exit 130' INT TERM HUP

case "${1:-}" in
  plan)
    ui_info "Настрою системный zsh, pinned Oh My Zsh, Starship и Ghostty."
    ;;
  detect|verify)
    shell_ready
    ;;
  apply)
    apply_shell
    ;;
  *)
    ui_fail "40-shell: неизвестное действие."
    exit 2
    ;;
esac
