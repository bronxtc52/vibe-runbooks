#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_OPEN_BIN="$TEST_ROOT/fake-bin/open"
  export VIBE_MAC_TEST_PAUSE=ok
  make_fake_command open 'printf "open:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"'
}

@test "workspace создаётся атомарно на feat/first-page без commit и remote" {
  run /bin/bash "$PROJECT_ROOT/steps/90-workspace.sh" apply

  [ "$status" -eq 0 ]
  workspace="$HOME/dev/hello-vibe"
  [ -f "$workspace/index.html" ]
  [ -f "$workspace/AGENTS.md" ]
  [ -f "$workspace/CLAUDE.md" ]
  [ -f "$workspace/FIRST-PROMPT.md" ]
  [ -f "$workspace/.mise.toml" ]
  [ "$(git -C "$workspace" branch --show-current)" = "feat/first-page" ]
  [ -z "$(git -C "$workspace" remote)" ]
  run git -C "$workspace" rev-parse --verify HEAD
  [ "$status" -ne 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "open:$workspace/index.html"
}

@test "существующий workspace остаётся byte-for-byte" {
  workspace="$HOME/dev/hello-vibe"
  mkdir -p "$workspace"
  printf '%s\n' keep >"$workspace/sentinel"
  before="$(shasum -a 256 "$workspace/sentinel" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/steps/90-workspace.sh" apply

  [ "$status" -ne 0 ]
  after="$(shasum -a 256 "$workspace/sentinel" | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ "$(find "$workspace" -mindepth 1 | wc -l | tr -d ' ')" -eq 1 ]
}
