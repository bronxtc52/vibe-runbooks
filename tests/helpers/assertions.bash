#!/usr/bin/env bash

assert_path_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    printf 'Ожидалось отсутствие пути: %s\n' "$1" >&2
    return 1
  fi
}

assert_file_contains() {
  local file pattern
  file="$1"
  pattern="$2"
  grep -F -- "$pattern" "$file" >/dev/null 2>&1
}

assert_no_events() {
  if [ -s "$VIBE_MAC_EVENT_LOG" ]; then
    printf 'Обнаружены запрещённые события:\n' >&2
    sed -n '1,120p' "$VIBE_MAC_EVENT_LOG" >&2
    return 1
  fi
}
