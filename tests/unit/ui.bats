#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
}

@test "ui_status печатает стабильный русский статус" {
  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/ui.sh"; ui_status "Установлено" "Homebrew"'

  [ "$status" -eq 0 ]
  [ "$output" = "[Установлено] Homebrew" ]
}

@test "ui_confirm принимает явное да в test mode" {
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/ui.sh"; ui_confirm "Продолжить?"'

  [ "$status" -eq 0 ]
}

@test "ui_confirm отклоняет пустой ответ" {
  export VIBE_MAC_TEST_RESPONSE=

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/ui.sh"; ui_confirm "Продолжить?"'

  [ "$status" -ne 0 ]
}
