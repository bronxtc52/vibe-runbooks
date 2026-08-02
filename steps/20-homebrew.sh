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
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

HOMEBREW_TEMP_DIR=
SUDO_VALIDATED=0

homebrew_installed() {
  local prefix expected
  if is_test_mode; then
    if [ -n "${VIBE_MAC_TEST_HOMEBREW_MARKER:-}" ]; then
      [ -f "$VIBE_MAC_TEST_HOMEBREW_MARKER" ]
      return
    fi
    [ "${VIBE_MAC_TEST_HOMEBREW:-missing}" = "installed" ]
    return
  fi

  configure_homebrew_path
  have brew || return 1
  prefix="$(brew --prefix 2>/dev/null)" || return 1
  expected="$(expected_homebrew_prefix)"
  [ "$prefix" = "$expected" ]
}

cleanup_homebrew() {
  local expected_root
  if [ "$SUDO_VALIDATED" = "1" ]; then
    /usr/bin/sudo -k || true
    SUDO_VALIDATED=0
  fi
  if [ -n "$HOMEBREW_TEMP_DIR" ]; then
    expected_root="${TMPDIR:-/tmp}/vibe-mac-homebrew."
    case "$HOMEBREW_TEMP_DIR" in
      "$expected_root"*)
        if [ -f "$HOMEBREW_TEMP_DIR/install.sh" ] &&
          [ ! -L "$HOMEBREW_TEMP_DIR/install.sh" ]; then
          /bin/unlink "$HOMEBREW_TEMP_DIR/install.sh"
        fi
        /bin/rmdir "$HOMEBREW_TEMP_DIR" 2>/dev/null || true
        ;;
      *)
        ui_warn "Отказ от очистки неожиданного temp path."
        ;;
    esac
    HOMEBREW_TEMP_DIR=
  fi
}

install_homebrew() {
  local installer url expected_prefix
  if homebrew_installed; then
    return 0
  fi

  if is_test_mode; then
    ui_info "Homebrew создаст служебные каталоги в ожидаемом prefix."
    if ! ui_confirm "Разрешаешь тестовую привилегированную фазу Homebrew?"; then
      return 1
    fi
    printf '%s\n' "homebrew:confirmed" >>"$VIBE_MAC_EVENT_LOG"
    printf '%s\n' "homebrew-install" >>"$VIBE_MAC_EVENT_LOG"
    if [ -n "${VIBE_MAC_TEST_HOMEBREW_MARKER:-}" ]; then
      : >"$VIBE_MAC_TEST_HOMEBREW_MARKER"
    fi
    return 0
  fi

  HOMEBREW_TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vibe-mac-homebrew.XXXXXX")"
  /bin/chmod 0700 "$HOMEBREW_TEMP_DIR"
  installer="$HOMEBREW_TEMP_DIR/install.sh"
  url="https://raw.githubusercontent.com/Homebrew/install/$HOMEBREW_INSTALL_COMMIT/install.sh"

  safe_download "$url" "$installer" "$HOMEBREW_INSTALL_SHA256"
  /bin/chmod 0700 "$installer"

  expected_prefix="$(expected_homebrew_prefix)"
  ui_info "Homebrew создаст служебные каталоги в $expected_prefix."
  ui_info "Pinned installer: $HOMEBREW_INSTALL_COMMIT"
  ui_info "SHA-256: $HOMEBREW_INSTALL_SHA256"
  ui_info "sudo нужен только официальному installer для системных каталогов."
  if ! ui_confirm "Разрешаешь короткую привилегированную фазу Homebrew?"; then
    cleanup_homebrew
    return 1
  fi

  /usr/bin/sudo -v
  SUDO_VALIDATED=1
  if NONINTERACTIVE=1 CI=1 /bin/bash "$installer"; then
    :
  else
    cleanup_homebrew
    return 1
  fi
  /usr/bin/sudo -k
  SUDO_VALIDATED=0
  cleanup_homebrew
  configure_homebrew_path
  homebrew_installed
}

trap cleanup_homebrew EXIT
trap 'exit 130' INT TERM HUP

case "${1:-}" in
  plan)
    ui_info "Установлю Homebrew из pinned official installer после SHA-256."
    ;;
  detect|verify)
    homebrew_installed
    ;;
  apply)
    install_homebrew
    ;;
  *)
    ui_fail "20-homebrew: неизвестное действие."
    exit 2
    ;;
esac
