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

SKIP_DEFAULTS="${SKIP_DEFAULTS:-0}"
export SKIP_DEFAULTS

defaults_bin() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_DEFAULTS_BIN:?test defaults не задан}"
  else
    printf '%s\n' /usr/bin/defaults
  fi
}

killall_bin() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_KILLALL_BIN:?test killall не задан}"
  else
    printf '%s\n' /usr/bin/killall
  fi
}

normalize_bool() {
  case "$1" in
    1|true|TRUE|YES|yes)
      printf '%s\n' true
      ;;
    0|false|FALSE|NO|no)
      printf '%s\n' false
      ;;
    *)
      return 2
      ;;
  esac
}

read_default_bool() {
  local domain key raw tool
  domain="$1"
  key="$2"
  tool="$(defaults_bin)"
  raw="$("$tool" read "$domain" "$key" 2>/dev/null)" || return 1
  normalize_bool "$raw"
}

capture_default() {
  local id domain key original_exists original_value json
  id="$1"
  domain="$2"
  key="$3"
  if json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  if original_value="$(read_default_bool "$domain" "$key")"; then
    original_exists=true
  else
    original_exists=false
    original_value=false
  fi
  json="{\"domain\":\"$domain\",\"key\":\"$key\",\"original_exists\":$original_exists,\"original_value\":$original_value,\"applied_value\":true}"
  json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" "defaults.$id" "$json"
}

default_is_true() {
  [ "$(read_default_bool "$1" "$2")" = true ]
}

defaults_ready() {
  if [ "$SKIP_DEFAULTS" = "1" ]; then
    return 0
  fi
  default_is_true com.apple.dock autohide &&
    default_is_true NSGlobalDomain AppleShowAllExtensions
}

apply_defaults() {
  local tool restarter dock_changed finder_changed
  if [ "$SKIP_DEFAULTS" = "1" ]; then
    ui_status "Пропущено" "Настройки macOS оставлены без изменений."
    return 0
  fi

  ui_info "Изменю только две настройки: Dock autohide и показ расширений Finder."
  if ! ui_confirm "Применить эти две обратимые настройки?"; then
    ui_warn "Настройки не изменены. Для явного пропуска перезапусти с SKIP_DEFAULTS=1."
    return 1
  fi
  if ! ui_pause "Dock/Finder могут на секунду перезапуститься после записи."; then
    return 1
  fi

  capture_default dock_autohide com.apple.dock autohide
  capture_default finder_extensions NSGlobalDomain AppleShowAllExtensions
  tool="$(defaults_bin)"
  restarter="$(killall_bin)"
  dock_changed=0
  finder_changed=0

  if ! default_is_true com.apple.dock autohide; then
    "$tool" write com.apple.dock autohide -bool true
    dock_changed=1
  fi
  if ! default_is_true NSGlobalDomain AppleShowAllExtensions; then
    "$tool" write NSGlobalDomain AppleShowAllExtensions -bool true
    finder_changed=1
  fi

  if [ "$dock_changed" = "1" ]; then
    "$restarter" Dock >/dev/null 2>&1 || true
  fi
  if [ "$finder_changed" = "1" ]; then
    "$restarter" Finder >/dev/null 2>&1 || true
  fi
  defaults_ready
}

case "${1:-}" in
  plan)
    if [ "$SKIP_DEFAULTS" = "1" ]; then
      ui_info "SKIP_DEFAULTS=1: настройки macOS не читаются и не меняются."
    else
      ui_info "Предложу Dock autohide и показ расширений Finder."
    fi
    ;;
  detect|verify)
    defaults_ready
    ;;
  apply)
    apply_defaults
    ;;
  *)
    ui_fail "80-defaults: неизвестное действие."
    exit 2
    ;;
esac
