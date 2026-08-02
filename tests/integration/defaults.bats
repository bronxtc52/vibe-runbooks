#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_DEFAULTS_STATE="$TEST_ROOT/defaults-state"
  export VIBE_MAC_DEFAULTS_BIN="$TEST_ROOT/fake-bin/defaults"
  export VIBE_MAC_KILLALL_BIN="$TEST_ROOT/fake-bin/killall"
  export VIBE_MAC_TEST_RESPONSE=да
  export VIBE_MAC_TEST_PAUSE=ok
  printf '%s\n' \
    'com.apple.dock:autohide=0' \
    'NSGlobalDomain:AppleShowAllExtensions=1' >"$VIBE_MAC_DEFAULTS_STATE"

  make_fake_command defaults '
    printf "defaults:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    key="${2:-}:${3:-}"
    case "${1:-}" in
      read)
        line="$(grep -F "$key=" "$VIBE_MAC_DEFAULTS_STATE" | tail -n 1)" || exit 1
        printf "%s\n" "${line#*=}"
        ;;
      write)
        value="${5:-}"
        grep -Fv "$key=" "$VIBE_MAC_DEFAULTS_STATE" >"$VIBE_MAC_DEFAULTS_STATE.next" || true
        printf "%s=%s\n" "$key" "$value" >>"$VIBE_MAC_DEFAULTS_STATE.next"
        mv "$VIBE_MAC_DEFAULTS_STATE.next" "$VIBE_MAC_DEFAULTS_STATE"
        ;;
      delete)
        grep -Fv "$key=" "$VIBE_MAC_DEFAULTS_STATE" >"$VIBE_MAC_DEFAULTS_STATE.next" || true
        mv "$VIBE_MAC_DEFAULTS_STATE.next" "$VIBE_MAC_DEFAULTS_STATE"
        ;;
    esac
  '
  make_fake_command killall \
    'printf "killall:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"'

  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init \
      "$PROJECT_ROOT/state/manifest-template.json" \
      "$VIBE_MAC_MANIFEST_FILE"
  '
}

@test "SKIP_DEFAULTS исключает чтение, запись и GUI" {
  export SKIP_DEFAULTS=1
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/80-defaults.sh" apply

  [ "$status" -eq 0 ]
  assert_no_events
}

@test "defaults не меняются без явного подтверждения" {
  export SKIP_DEFAULTS=0
  export VIBE_MAC_TEST_RESPONSE=нет
  : >"$VIBE_MAC_EVENT_LOG"
  before="$(shasum -a 256 "$VIBE_MAC_DEFAULTS_STATE" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/steps/80-defaults.sh" apply

  [ "$status" -ne 0 ]
  after="$(shasum -a 256 "$VIBE_MAC_DEFAULTS_STATE" | awk '{print $1}')"
  [ "$before" = "$after" ]
  assert_no_events
}

@test "defaults сохраняют исходные bool в manifest и применяются один раз" {
  export SKIP_DEFAULTS=0

  run /bin/bash "$PROJECT_ROOT/steps/80-defaults.sh" apply
  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_DEFAULTS_STATE" "com.apple.dock:autohide=true"
  assert_file_contains "$VIBE_MAC_DEFAULTS_STATE" "NSGlobalDomain:AppleShowAllExtensions=1"

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract defaults.dock_autohide raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"original_value":false'* ]]
  [[ "$output" == *'"applied_value":true'* ]]

  first_writes="$(grep -c '^defaults:write' "$VIBE_MAC_EVENT_LOG")"
  [ "$first_writes" -eq 1 ]
  run /bin/bash "$PROJECT_ROOT/steps/80-defaults.sh" apply
  [ "$status" -eq 0 ]
  second_writes="$(grep -c '^defaults:write' "$VIBE_MAC_EVENT_LOG")"
  [ "$first_writes" -eq "$second_writes" ]
}
