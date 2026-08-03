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

CLAUDE_BIN=
CODEX_BIN=
CURSOR_AGENT_BIN=

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

required_homebrew_executable() {
  local name prefix candidate status
  name="$1"
  case "$name" in
    claude|codex|cursor-agent) ;;
    *) return 2 ;;
  esac
  prefix="$(step_expected_homebrew_prefix)" || return 2
  status=0
  candidate="$(homebrew_executable_in_prefix "$prefix" "$name")" || status="$?"
  if [ "$status" -ne 0 ]; then
    ui_fail "Не найден безопасный Homebrew executable: $prefix/bin/$name."
    return "$status"
  fi
  printf '%s\n' "$candidate"
}

resolve_ai_tools() {
  CLAUDE_BIN="$(required_homebrew_executable claude)" || return "$?"
  CODEX_BIN="$(required_homebrew_executable codex)" || return "$?"
  CURSOR_AGENT_BIN="$(required_homebrew_executable cursor-agent)" || return "$?"
}

run_ai_command() {
  local command_bin prefix clean_path run_user safe_cwd config_dir
  local command_home command_tmp
  command_bin="$1"
  shift
  case "$command_bin" in
    "$CLAUDE_BIN"|"$CODEX_BIN"|"$CURSOR_AGENT_BIN") ;;
    *) return 2 ;;
  esac
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
  safe_cwd="$(cd /var/empty && pwd -P)" || return 2
  for config_dir in "$HOME/.claude" "$HOME/.codex" "$HOME/.cursor"; do
    validate_home_dir_path "$config_dir" || return 2
  done
  command_home="$HOME"
  if is_test_mode; then
    command_tmp="${TMPDIR:-/tmp}"
  else
    command_tmp=/tmp
  fi
  if [ "${1:-}" = --version ]; then
    # Version probes must not initialize agent state or auto-update in HOME.
    command_home=/var/empty
    command_tmp=/var/empty
  fi
  if is_test_mode; then
    (
      cd "$safe_cwd"
      /usr/bin/env -i \
        HOME="$command_home" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
        PATH="$clean_path" TMPDIR="$command_tmp" LC_ALL=C \
        TERM=xterm-256color NO_COLOR=1 \
        DO_NOT_TRACK=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        TEST_ROOT="${TEST_ROOT:-}" \
        VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
        VIBE_MAC_TEST_CLAUDE_LOGIN_FAIL="${VIBE_MAC_TEST_CLAUDE_LOGIN_FAIL:-0}" \
        "$command_bin" "$@"
    )
    return
  fi
  (
    cd "$safe_cwd"
    /usr/bin/env -i \
      HOME="$command_home" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
      PATH="$clean_path" TMPDIR="$command_tmp" LC_ALL=C \
      TERM=xterm-256color NO_COLOR=1 \
      DO_NOT_TRACK=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      "$command_bin" "$@"
  )
}

cursor_app_path() {
  if is_test_mode; then
    [ -n "${VIBE_MAC_TEST_CURSOR_APP:-}" ] || return 1
    printf '%s\n' "$VIBE_MAC_TEST_CURSOR_APP"
    return
  fi
  printf '%s\n' /Applications/Cursor.app
}

run_cursor_open() {
  local open_bin cursor_app run_user safe_cwd
  open_bin="$1"
  cursor_app="$2"
  if is_test_mode; then
    [ "$open_bin" = "${VIBE_MAC_OPEN_BIN:?test open не задан}" ] || return 2
  else
    [ "$open_bin" = /usr/bin/open ] || return 2
  fi
  run_user="$(/usr/bin/id -un)" || return 2
  [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
  safe_cwd="$(cd /var/empty && pwd -P)" || return 2
  if is_test_mode; then
    (
      cd "$safe_cwd"
      /usr/bin/env -i \
        HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        TMPDIR="${TMPDIR:-/tmp}" LC_ALL=C \
        VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
        "$open_bin" "$cursor_app"
    )
    return
  fi
  (
    cd "$safe_cwd"
    /usr/bin/env -i \
      HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp LC_ALL=C \
      "$open_bin" "$cursor_app"
  )
}

ai_ready() {
  local cursor_app
  cursor_app="$(cursor_app_path)" || return 1
  resolve_ai_tools || return "$?"
  macos_app_bundle_ready "$cursor_app" || return 1
  if [ "${DRY_RUN:-0}" = 1 ] &&
    [ "${VIBE_MAC_FULL_VERIFY:-0}" != 1 ]; then
    return 0
  fi
  run_ai_command "$CLAUDE_BIN" --version >/dev/null 2>&1 || return "$?"
  run_ai_command "$CODEX_BIN" --version >/dev/null 2>&1 || return "$?"
  run_ai_command "$CURSOR_AGENT_BIN" --version >/dev/null 2>&1 || return "$?"
}

claude_authenticated() {
  run_ai_command "$CLAUDE_BIN" auth status --text >/dev/null 2>&1
}

codex_authenticated() {
  run_ai_command "$CODEX_BIN" login status >/dev/null 2>&1
}

cursor_agent_authenticated() {
  run_ai_command "$CURSOR_AGENT_BIN" status >/dev/null 2>&1
}

maybe_login() {
  local label status_function manual_command
  label="$1"
  status_function="$2"
  manual_command="$3"
  shift 3

  if "$status_function"; then
    ui_status "Уже стоит" "Вход $label уже выполнен."
    return 0
  fi
  ui_info "Для $label откроется официальный вход через системный браузер; ключи не нужны."
  if ! ui_confirm "Начать вход в $label?"; then
    ui_warn "Вход в $label отложен. Позже выполни: $manual_command"
    return 0
  fi

  if ! "$@"; then
    ui_warn "Вход $label не завершён. Повтори: $manual_command"
    return 0
  fi
  if "$status_function"; then
    ui_success "Вход $label"
  else
    ui_warn "Вход $label не подтверждён. Повтори: $manual_command"
  fi
}

open_cursor_login() {
  local open_bin cursor_app cursor_app_quoted manual_command
  manual_command='/usr/bin/open /Applications/Cursor.app'
  ui_info "Cursor Desktop проверяет вход только в своём интерфейсе."
  if ! ui_confirm "Открыть Cursor для ручного входа?"; then
    ui_warn "Вход Cursor Desktop отложен. Позже выполни: $manual_command"
    return 0
  fi
  if is_test_mode; then
    open_bin="${VIBE_MAC_OPEN_BIN:?test open не задан}"
  else
    open_bin=/usr/bin/open
  fi
  cursor_app="$(cursor_app_path)" || {
    ui_warn "Безопасный путь Cursor не найден. После исправления выполни: $manual_command"
    return 0
  }
  printf -v cursor_app_quoted '%q' "$cursor_app"
  manual_command="$open_bin $cursor_app_quoted"
  if ! macos_app_bundle_ready "$cursor_app"; then
    ui_warn "Безопасный Cursor.app не найден. После исправления выполни: $manual_command"
    return 0
  fi
  if ! run_cursor_open "$open_bin" "$cursor_app"; then
    ui_warn "Cursor не открылся. Повтори: $manual_command"
  fi
}

apply_ai_logins() {
  local ready_status prefix
  if ai_ready; then
    :
  else
    ready_status="$?"
    ui_fail "AI-команды установлены не полностью; повтори шаг 30-brew-bundle."
    return "$ready_status"
  fi

  prefix="$(step_expected_homebrew_prefix)" || return 2
  maybe_login "Claude" claude_authenticated \
    "$prefix/bin/claude auth login" \
    run_ai_command "$CLAUDE_BIN" auth login
  maybe_login "Codex" codex_authenticated \
    "$prefix/bin/codex login" \
    run_ai_command "$CODEX_BIN" login
  maybe_login "Cursor Agent" cursor_agent_authenticated \
    "$prefix/bin/cursor-agent login" \
    run_ai_command "$CURSOR_AGENT_BIN" login
  open_cursor_login
}

case "${1:-}" in
  plan)
    ui_info "Проверю Claude, Codex и Cursor и предложу вход через системный браузер."
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
