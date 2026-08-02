#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_RESPONSE=да
  export VIBE_MAC_STEPS_DIR="$TEST_ROOT/steps"
  export VIBE_MAC_STEP_IDS="00-one 10-fails-once"
  mkdir -p "$VIBE_MAC_STEPS_DIR"

  for step_id in 00-one 10-fails-once; do
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf '%s\n' 'set -euo pipefail'
      printf '%s\n' 'action="${1:-}"'
      printf '%s\n' 'id="'"$step_id"'"'
      printf '%s\n' 'marker="$VIBE_MAC_RUNTIME_ROOT/test-markers/$id"'
      printf '%s\n' 'case "$action" in'
      printf '%s\n' '  plan) : ;;'
      printf '%s\n' '  detect|verify) [ -f "$marker" ] ;;'
      printf '%s\n' '  apply)'
      printf '%s\n' '    printf "apply:%s\n" "$id" >>"$VIBE_MAC_EVENT_LOG"'
      printf '%s\n' '    if [ "$id" = "10-fails-once" ] && [ ! -f "$TEST_ROOT/failure-used" ]; then'
      printf '%s\n' '      : >"$TEST_ROOT/failure-used"; exit 1'
      printf '%s\n' '    fi'
      printf '%s\n' '    mkdir -p "$(dirname "$marker")"; : >"$marker" ;;'
      printf '%s\n' '  *) exit 2 ;;'
      printf '%s\n' 'esac'
    } >"$VIBE_MAC_STEPS_DIR/$step_id.sh"
    chmod +x "$VIBE_MAC_STEPS_DIR/$step_id.sh"
  done
}

@test "после сбоя повторяется только незавершённый шаг" {
  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -ne 0 ]

  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ "$(grep -c '^apply:00-one$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^apply:10-fails-once$' "$VIBE_MAC_EVENT_LOG")" -eq 2 ]
}
