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

ai_ready() {
  if is_test_mode; then
    [ "${VIBE_MAC_TEST_AI_READY:-0}" = "1" ]
    return
  fi
  have claude &&
    have codex &&
    have cursor &&
    have cursor-agent &&
    [ -d /Applications/Cursor.app ]
}

claude_authenticated() {
  claude auth status --text >/dev/null 2>&1
}

codex_authenticated() {
  codex login status >/dev/null 2>&1
}

cursor_agent_authenticated() {
  cursor-agent status >/dev/null 2>&1
}

maybe_login() {
  local label status_function
  label="$1"
  status_function="$2"
  shift 2

  if "$status_function"; then
    ui_status "Уже стоит" "Вход $label уже выполнен."
    return 0
  fi
  ui_info "Для $label откроется официальный browser login; ключи не нужны."
  if ! ui_confirm "Начать вход в $label?"; then
    ui_warn "Вход в $label отложен. Установленные команды продолжат работать после ручного login."
    return 0
  fi

  "$@"
  if "$status_function"; then
    ui_success "Вход $label"
  else
    ui_warn "Вход $label не подтверждён status-командой; его можно завершить позже."
  fi
}

open_cursor_login() {
  local open_bin
  ui_info "Cursor Desktop проверяет вход только в своём интерфейсе."
  if ! ui_confirm "Открыть Cursor для ручного входа?"; then
    ui_warn "Вход Cursor Desktop отложен."
    return 0
  fi
  if is_test_mode; then
    open_bin="${VIBE_MAC_OPEN_BIN:?test open не задан}"
  else
    open_bin=/usr/bin/open
  fi
  "$open_bin" -a Cursor
}

apply_ai_logins() {
  if ! ai_ready; then
    ui_fail "AI-команды установлены не полностью; повтори шаг 30-brew-bundle."
    return 1
  fi

  maybe_login "Claude" claude_authenticated claude auth login
  maybe_login "Codex" codex_authenticated codex login
  maybe_login "Cursor Agent" cursor_agent_authenticated cursor-agent login
  open_cursor_login
}

case "${1:-}" in
  plan)
    ui_info "Проверю Claude, Codex, Cursor и по желанию проведу browser login."
    ;;
  detect|verify)
    ai_ready
    ;;
  apply)
    apply_ai_logins
    ;;
  *)
    ui_fail "60-ai-agents: неизвестное действие."
    exit 2
    ;;
esac
