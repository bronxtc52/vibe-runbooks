#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export STATE_FILE="$TEST_ROOT/state/progress.json"
  export STATE_TEMPLATE="$PROJECT_ROOT/state/progress-template.json"
}

@test "state создаётся из валидного шаблона и меняется атомарно" {
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
    [ "$(state_get_status "$STATE_FILE" "00-preflight")" = "pending" ]
    state_mark_complete "$STATE_FILE" "00-preflight" "2026-08-02T00:00:00Z"
    [ "$(state_get_status "$STATE_FILE" "00-preflight")" = "completed" ]
  '

  [ "$status" -eq 0 ]
  [ -f "$STATE_FILE" ]
}

@test "ошибка plutil не повреждает прежний state" {
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
  '
  [ "$status" -eq 0 ]
  before="$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')"

  export PLUTIL_STUB_FAIL_REPLACE=1
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_mark_complete "$STATE_FILE" "00-preflight" "2026-08-02T00:00:00Z"
  '

  [ "$status" -ne 0 ]
  after="$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "manifest создаётся с известной schema без персональных данных" {
  manifest="$TEST_ROOT/state/manifest.json"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$1"
    [ "$(json_extract_raw "$1" schema_version)" = "1" ]
  ' _ "$manifest"

  [ "$status" -eq 0 ]
  ! grep -F "$USER" "$manifest"
}
