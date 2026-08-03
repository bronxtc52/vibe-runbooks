#!/usr/bin/env bash
set -euo pipefail

STEP_PATH="$(/bin/realpath "$0" 2>/dev/null)" || exit 2
STEP_DIR="${STEP_PATH%/*}"
VIBE_MAC_ROOT="${STEP_DIR%/*}"
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
HOMEBREW_CLEAN_HOME=
SUDO_VALIDATED=0

step_expected_homebrew_prefix() {
  if is_test_mode &&
    [ -n "${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" ]; then
    case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
      /*)
        case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
          *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;;
        esac
        printf '%s\n' "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX"
        return 0
        ;;
      *) return 2 ;;
    esac
  fi
  expected_homebrew_prefix
}

homebrew_probe_run() {
  local prefix brew_bin clean_path run_user config_home
  prefix="$(step_expected_homebrew_prefix)" || return 2
  homebrew_env_files_safe "$prefix" || return 2
  brew_bin="$(homebrew_executable_in_prefix "$prefix" brew)" || return "$?"
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  config_home=/var/empty
  [ -d "$config_home" ] && [ ! -L "$config_home" ] || return 2

  if is_test_mode; then
    /usr/bin/env -i \
      HOME="$HOME" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      PATH="$clean_path" \
      TMPDIR="${TMPDIR:-/tmp}" \
      LC_ALL=C \
      HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_INSTALL_UPGRADE=1 \
      HOMEBREW_NO_INSTALL_CLEANUP=1 \
      HOMEBREW_NO_ANALYTICS=1 \
      HOMEBREW_NO_ENV_HINTS=1 \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      CURL_HOME="$config_home" \
      XDG_CONFIG_HOME="$config_home" \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" \
      "$brew_bin" "$@"
    return
  fi

  /usr/bin/env -i \
    HOME="$HOME" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    PATH="$clean_path" \
    TMPDIR=/tmp \
    LC_ALL=C \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_INSTALL_UPGRADE=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    CURL_HOME="$config_home" \
    XDG_CONFIG_HOME="$config_home" \
    "$brew_bin" "$@"
}

homebrew_installed() {
  local prefix brew_bin actual
  if is_test_mode; then
    if [ -n "${VIBE_MAC_TEST_HOMEBREW_MARKER:-}" ]; then
      [ -f "$VIBE_MAC_TEST_HOMEBREW_MARKER" ]
      return
    fi
    [ "${VIBE_MAC_TEST_HOMEBREW:-missing}" = "installed" ] || return 1
  fi

  prefix="$(step_expected_homebrew_prefix)" || return 2
  brew_bin="$(homebrew_executable_in_prefix "$prefix" brew)" || return "$?"
  if [ "${DRY_RUN:-0}" = "1" ] &&
    [ "${VIBE_MAC_FULL_VERIFY:-0}" != "1" ]; then
    return 0
  fi
  actual="$(homebrew_probe_run --prefix 2>/dev/null)" || return 1
  [ "$actual" = "$prefix" ] || return 1
  homebrew_probe_run --version >/dev/null 2>&1 || return 1
}

cleanup_homebrew() {
  local expected_root clean_prefix
  if [ "$SUDO_VALIDATED" = "1" ]; then
    /usr/bin/sudo -k || true
    SUDO_VALIDATED=0
  fi
  if [ -n "$HOMEBREW_CLEAN_HOME" ]; then
    if is_test_mode; then
      clean_prefix="${TMPDIR:-/tmp}/vibe-mac-homebrew-home."
    else
      clean_prefix=/tmp/vibe-mac-homebrew-home.
    fi
    case "$HOMEBREW_CLEAN_HOME" in
      "$clean_prefix"*)
        if [ -d "$HOMEBREW_CLEAN_HOME" ] &&
          [ ! -L "$HOMEBREW_CLEAN_HOME" ]; then
          /usr/bin/find "$HOMEBREW_CLEAN_HOME" -depth -delete
        fi
        ;;
      *) ui_warn "Отказ от очистки неожиданного clean HOME." ;;
    esac
    HOMEBREW_CLEAN_HOME=
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

run_homebrew_installer_clean() {
  local installer run_user config_home prefix clean_base original_home
  installer="$1"
  [ -f "$installer" ] && [ ! -L "$installer" ] || {
    ui_fail "Homebrew installer отсутствует или является symlink."
    return 2
  }
  run_user="$(/usr/bin/id -un)" || return 2
  prefix="$(step_expected_homebrew_prefix)" || return 2
  homebrew_env_files_safe "$prefix" || return 2
  config_home=/var/empty
  [ -d "$config_home" ] && [ ! -L "$config_home" ] || return 2
  original_home="$HOME"
  if is_test_mode; then
    clean_base="${TMPDIR:-/tmp}"
  else
    clean_base=/tmp
  fi
  HOMEBREW_CLEAN_HOME="$(/usr/bin/mktemp -d \
    "$clean_base/vibe-mac-homebrew-home.XXXXXX")" || return 1
  /bin/chmod 0700 "$HOMEBREW_CLEAN_HOME"

  if is_test_mode; then
    /usr/bin/env -i \
      HOME="$HOMEBREW_CLEAN_HOME" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      ZDOTDIR="$original_home" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      TMPDIR="${TMPDIR:-/tmp}" \
      LC_ALL=C \
      NONINTERACTIVE=1 \
      CI=1 \
      HOMEBREW_NO_ANALYTICS=1 \
      HOMEBREW_NO_ENV_HINTS=1 \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      CURL_HOME="$config_home" \
      XDG_CONFIG_HOME="$config_home" \
      VIBE_MAC_TEST_RESULT_DIR="$original_home" \
      /bin/bash --noprofile --norc "$installer"
    return
  fi

  /usr/bin/env -i \
    HOME="$HOMEBREW_CLEAN_HOME" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    ZDOTDIR="$original_home" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR=/tmp \
    LC_ALL=C \
    NONINTERACTIVE=1 \
    CI=1 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    CURL_HOME="$config_home" \
    XDG_CONFIG_HOME="$config_home" \
    /bin/bash --noprofile --norc "$installer"
}

show_homebrew_privilege_effects() {
  local architecture prefix repository cache
  architecture="$(guard_architecture)" || return 2
  prefix="$(step_expected_homebrew_prefix)" || return 2
  cache="$HOME/Library/Caches/Homebrew"
  case "$cache" in
    /*)
      case "$cache" in *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac

  ui_info "Перед вводом пароля Mac официальный установщик сможет:"
  case "$architecture" in
    arm64)
      ui_info "  1. Создать $prefix и каталоги Homebrew только внутри него."
      ui_info "  2. Исправить владельца, группу и права у $prefix и каталогов Homebrew внутри него."
      ui_info "  3. Создать или обновить /etc/paths.d/homebrew; внутри будет только $prefix/bin."
      ;;
    x86_64)
      repository="$prefix/Homebrew"
      ui_info "  1. Создать $repository и каталоги Homebrew внутри $prefix."
      ui_info "  2. Исправить владельца, группу и права только у каталогов Homebrew внутри $prefix."
      ui_info "  3. Не менять /etc/paths.d/homebrew: $prefix/bin уже входит в системный путь."
      ;;
    *) return 2 ;;
  esac
  ui_info "  4. При необходимости исправить права кэша Homebrew: $cache."
  ui_info "После установки доступ администратора будет сразу закрыт."
}

install_homebrew() {
  local installer url expected_prefix
  if homebrew_installed; then
    return 0
  fi

  if is_test_mode; then
    show_homebrew_privilege_effects
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
  show_homebrew_privilege_effects
  if ! ui_confirm "Разрешаешь короткую привилегированную фазу Homebrew?"; then
    cleanup_homebrew
    return 1
  fi

  /usr/bin/sudo -v
  SUDO_VALIDATED=1
  if run_homebrew_installer_clean "$installer"; then
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
    ui_info "Скачаю официальный установщик Homebrew, проверю его подлинность и заранее покажу системные изменения."
    ;;
  detect|verify)
    homebrew_installed
    ;;
  apply)
    install_homebrew
    ;;
  test-run-clean-installer)
    if ! is_test_mode ||
      [ -z "${VIBE_MAC_TEST_HOMEBREW_INSTALLER:-}" ]; then
      ui_fail "20-homebrew: test action недоступен."
      exit 2
    fi
    run_homebrew_installer_clean "$VIBE_MAC_TEST_HOMEBREW_INSTALLER"
    ;;
  *)
    ui_fail "20-homebrew: неизвестное действие."
    exit 2
    ;;
esac
