#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_RESPONSE=да
  export VIBE_MAC_STEPS_DIR="$TEST_ROOT/steps"
  export VIBE_MAC_STEP_IDS="00-one 10-two"
  mkdir -p "$VIBE_MAC_STEPS_DIR"
  write_step 00-one
  write_step 10-two
}

write_step() {
  local step_id
  step_id="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'action="${1:-}"'
    printf '%s\n' 'marker="$VIBE_MAC_RUNTIME_ROOT/test-markers/'"$step_id"'"'
    printf '%s\n' 'case "$action" in'
    printf '%s\n' '  plan) printf "plan %s\n" "'"$step_id"'" ;;'
    printf '%s\n' '  detect|verify) [ -f "$marker" ] ;;'
    printf '%s\n' '  apply) mkdir -p "$(dirname "$marker")"; : >"$marker"; printf "apply:%s\n" "'"$step_id"'" >>"$VIBE_MAC_EVENT_LOG" ;;'
    printf '%s\n' '  *) exit 2 ;;'
    printf '%s\n' 'esac'
  } >"$VIBE_MAC_STEPS_DIR/$step_id.sh"
  chmod +x "$VIBE_MAC_STEPS_DIR/$step_id.sh"
}

@test "install выполняет шаги по порядку, а второй запуск не мутирует" {
  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$VIBE_MAC_EVENT_LOG")" = "apply:00-one" ]
  [ "$(sed -n '2p' "$VIBE_MAC_EVENT_LOG")" = "apply:10-two" ]

  first_hash="$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')"
  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  second_hash="$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')"
  [ "$first_hash" = "$second_hash" ]
}

@test "pending onboarding применяется один раз даже при зелёном verify" {
  export VIBE_MAC_STEP_IDS="60-ai-agents"
  write_step 60-ai-agents
  mkdir -p "$VIBE_MAC_RUNTIME_ROOT/test-markers"
  : >"$VIBE_MAC_RUNTIME_ROOT/test-markers/60-ai-agents"

  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apply:60-ai-agents$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]

  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apply:60-ai-agents$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
}

@test "CLT не вызывает GUI без human gate" {
  export VIBE_MAC_TEST_CLT_MARKER="$TEST_ROOT/clt-installed"
  export VIBE_MAC_TEST_PAUSE=deny
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/10-xcode-clt.sh" apply

  [ "$status" -ne 0 ]
  assert_path_absent "$VIBE_MAC_TEST_CLT_MARKER"
  assert_no_events
}

@test "CLT вызывает системный шаг только после Enter" {
  export VIBE_MAC_TEST_CLT_MARKER="$TEST_ROOT/clt-installed"
  export VIBE_MAC_TEST_PAUSE=ok
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/10-xcode-clt.sh" apply

  [ "$status" -eq 0 ]
  [ -f "$VIBE_MAC_TEST_CLT_MARKER" ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "xcode-select --install"
}

@test "Homebrew не начинает privileged phase без да" {
  export VIBE_MAC_TEST_HOMEBREW_MARKER="$TEST_ROOT/homebrew-installed"
  export VIBE_MAC_TEST_RESPONSE=нет
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" apply

  [ "$status" -ne 0 ]
  assert_path_absent "$VIBE_MAC_TEST_HOMEBREW_MARKER"
  assert_no_events
}

@test "Homebrew после да проходит test privileged trace" {
  export VIBE_MAC_TEST_HOMEBREW_MARKER="$TEST_ROOT/homebrew-installed"
  export VIBE_MAC_TEST_RESPONSE=да
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" apply

  [ "$status" -eq 0 ]
  [ -f "$VIBE_MAC_TEST_HOMEBREW_MARKER" ]
  [ "$(sed -n '1p' "$VIBE_MAC_EVENT_LOG")" = "homebrew:confirmed" ]
  [ "$(sed -n '2p' "$VIBE_MAC_EVENT_LOG")" = "homebrew-install" ]
}
