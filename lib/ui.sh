#!/usr/bin/env bash
set -euo pipefail

ui_status() {
  local status message
  status="$1"
  message="$2"
  printf '[%s] %s\n' "$status" "$message"
}

ui_info() {
  printf '• %s\n' "$1"
}

ui_success() {
  ui_status "Установлено" "$1"
}

ui_warn() {
  printf 'Внимание: %s\n' "$1" >&2
}

ui_fail() {
  printf 'Ошибка: %s\n' "$1" >&2
}

ui_read_answer() {
  local answer
  answer=
  if [ "${VIBE_MAC_TEST_MODE:-0}" = "1" ]; then
    answer="${VIBE_MAC_TEST_RESPONSE:-}"
  elif [ -r /dev/tty ]; then
    IFS= read -r answer </dev/tty || return 1
  else
    return 1
  fi
  printf '%s\n' "$answer"
}

ui_confirm() {
  local prompt answer
  prompt="$1"
  printf '%s [да/нет]: ' "$prompt"
  if ! answer="$(ui_read_answer)"; then
    printf '\n'
    ui_warn "Нет интерактивного Терминала; действие не выполнено."
    return 1
  fi
  printf '\n'
  case "$answer" in
    да|Да|ДА|д|Д|yes|Yes|YES|y|Y)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ui_confirm_typed() {
  local prompt expected answer
  prompt="$1"
  expected="$2"
  printf '%s Введи %s: ' "$prompt" "$expected"
  if ! answer="$(ui_read_answer)"; then
    printf '\n'
    ui_warn "Нет интерактивного Терминала; действие не выполнено."
    return 1
  fi
  printf '\n'
  [ "$answer" = "$expected" ]
}

ui_pause() {
  local prompt
  prompt="$1"
  printf '%s Нажми Enter: ' "$prompt"
  if [ "${VIBE_MAC_TEST_MODE:-0}" = "1" ]; then
    printf '\n'
    [ "${VIBE_MAC_TEST_PAUSE:-ok}" = "ok" ]
    return
  fi
  if [ ! -r /dev/tty ]; then
    printf '\n'
    ui_warn "Нет интерактивного Терминала; действие не выполнено."
    return 1
  fi
  IFS= read -r _ </dev/tty
}
