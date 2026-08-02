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
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

DRY_RUN="${DRY_RUN:-0}"
EXTRAS="${EXTRAS:-0}"
SKIP_DEFAULTS="${SKIP_DEFAULTS:-0}"
ALLOW_UNSUPPORTED_INTEL="${ALLOW_UNSUPPORTED_INTEL:-0}"
export DRY_RUN EXTRAS SKIP_DEFAULTS ALLOW_UNSUPPORTED_INTEL

STATE_TEMPLATE="$VIBE_MAC_ROOT/state/progress-template.json"
MANIFEST_TEMPLATE="$VIBE_MAC_ROOT/state/manifest-template.json"
export STATE_TEMPLATE MANIFEST_TEMPLATE

if is_test_mode && [ -n "${VIBE_MAC_STEPS_DIR:-}" ]; then
  STEPS_DIR="$VIBE_MAC_STEPS_DIR"
else
  STEPS_DIR="$VIBE_MAC_ROOT/steps"
fi

if is_test_mode && [ -n "${VIBE_MAC_STEP_IDS:-}" ]; then
  STEP_IDS="$VIBE_MAC_STEP_IDS"
else
  STEP_IDS="00-preflight 10-xcode-clt 20-homebrew 30-brew-bundle 40-shell 50-runtimes"
fi

LOCK_HELD=0
CURRENT_STEP=bootstrap

usage() {
  printf '%s\n' \
    "vibe-mac $VIBE_MAC_VERSION" \
    "Запуск: /bin/bash ./install.sh" \
    "Флаги окружения: DRY_RUN=1 EXTRAS=1 SKIP_DEFAULTS=1"
}

validate_step_id() {
  case "$1" in
    [0-9][0-9]-[A-Za-z0-9-]*)
      return 0
      ;;
    *)
      ui_fail "Некорректный ID шага: $1."
      return 2
      ;;
  esac
}

step_file() {
  local step file
  step="$1"
  validate_step_id "$step"
  file="$STEPS_DIR/$step.sh"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    ui_fail "Не найден безопасный файл шага: $file."
    return 2
  fi
  printf '%s\n' "$file"
}

run_step() {
  local step action file
  step="$1"
  action="$2"
  file="$(step_file "$step")"
  /bin/bash "$file" "$action"
}

state_complete_if_known() {
  local step status
  step="$1"
  if state_has_step "$VIBE_MAC_STATE_FILE" "$step"; then
    status="$(state_get_status "$VIBE_MAC_STATE_FILE" "$step")"
    if [ "$status" != "completed" ]; then
      state_mark_complete "$VIBE_MAC_STATE_FILE" "$step" "$(utc_now)"
    fi
  elif ! is_test_mode; then
    ui_fail "Шаг отсутствует в progress schema: $step."
    return 2
  fi
}

cleanup() {
  local exit_code
  exit_code="$?"
  if [ "$LOCK_HELD" = "1" ]; then
    release_lock || true
    LOCK_HELD=0
  fi
  if [ "$exit_code" -ne 0 ]; then
    if [ -n "$VIBE_MAC_LOG_FILE" ]; then
      ui_fail "Остановились на шаге $CURRENT_STEP. Лог: $VIBE_MAC_LOG_FILE"
    else
      ui_fail "Остановились до создания лога."
    fi
  fi
  return "$exit_code"
}

run_dry_plan() {
  local step
  ui_info "DRY_RUN: только читаю состояние; сеть, записи, sudo и GUI запрещены."
  for step in $STEP_IDS; do
    CURRENT_STEP="$step"
    if run_step "$step" verify >/dev/null 2>&1; then
      ui_status "Уже стоит" "$step"
    else
      run_step "$step" plan
      ui_status "Пропущено" "DRY_RUN: $step"
    fi
  done
  ui_info "DRY_RUN завершён без изменений."
}

run_install() {
  local step

  init_runtime_layout
  acquire_lock
  LOCK_HELD=1
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  state_init "$STATE_TEMPLATE" "$VIBE_MAC_STATE_FILE"
  manifest_init "$MANIFEST_TEMPLATE" "$VIBE_MAC_MANIFEST_FILE"
  init_log
  log_event info bootstrap "Начат vibe-mac $VIBE_MAC_VERSION."

  for step in $STEP_IDS; do
    CURRENT_STEP="$step"
    log_event info "$step" "Проверка шага."

    if run_step "$step" verify >/dev/null 2>&1; then
      state_complete_if_known "$step"
      ui_status "Уже стоит" "$step"
      log_event success "$step" "Уже стоит."
      continue
    fi

    run_step "$step" plan
    if run_step "$step" apply; then
      :
    else
      log_event error "$step" "Apply завершился ошибкой."
      ui_status "Ошибка" "$step"
      return 1
    fi

    if ! run_step "$step" verify >/dev/null 2>&1; then
      log_event error "$step" "Проверка после apply не прошла."
      ui_status "Ошибка" "$step"
      return 1
    fi

    state_complete_if_known "$step"
    ui_status "Установлено" "$step"
    log_event success "$step" "Установлено."
  done

  CURRENT_STEP=complete
  log_event success complete "Техническая установка завершена."
  ui_info "Техническая установка завершена."
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --version)
    printf '%s\n' "$VIBE_MAC_VERSION"
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

guard_preflight

if [ "$DRY_RUN" = "1" ]; then
  run_dry_plan
else
  run_install
fi
