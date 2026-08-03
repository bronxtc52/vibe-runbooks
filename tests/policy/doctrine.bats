#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_OPEN_BIN="$TEST_ROOT/fake-bin/open"
  export VIBE_MAC_TEST_PAUSE=deny
  make_fake_command open 'exit 0'
}

@test "AGENTS и CLAUDE templates содержат security и Git doctrine" {
  for file in "$PROJECT_ROOT/config/AGENTS.md" "$PROJECT_ROOT/config/CLAUDE.md"; do
    assert_file_contains "$file" "kv-bronxtc-dev"
    assert_file_contains "$file" "PII/PHI"
    assert_file_contains "$file" "git add -A"
    assert_file_contains "$file" "--no-verify"
    assert_file_contains "$file" "force-push"
    assert_file_contains "$file" "main"
  done
}

@test "workspace step не меняет глобальные agent-файлы" {
  mkdir -p "$HOME/.codex" "$HOME/.claude"
  printf '%s\n' codex-canary >"$HOME/.codex/AGENTS.md"
  printf '%s\n' claude-canary >"$HOME/.claude/CLAUDE.md"
  before_codex="$(shasum -a 256 "$HOME/.codex/AGENTS.md" | awk '{print $1}')"
  before_claude="$(shasum -a 256 "$HOME/.claude/CLAUDE.md" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/steps/90-workspace.sh" apply

  [ "$status" -eq 0 ]
  [ "$before_codex" = "$(shasum -a 256 "$HOME/.codex/AGENTS.md" | awk '{print $1}')" ]
  [ "$before_claude" = "$(shasum -a 256 "$HOME/.claude/CLAUDE.md" | awk '{print $1}')" ]
}
