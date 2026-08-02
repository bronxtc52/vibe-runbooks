#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_AI_READY=1
  export VIBE_MAC_OPEN_BIN="$TEST_ROOT/fake-bin/open"

  make_fake_command claude '
    printf "claude:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
      printf "%s\n" "token=CANARY_AUTH_OUTPUT"
      [ -f "$TEST_ROOT/claude-auth" ]
    elif [ "${1:-}" = "auth" ] && [ "${2:-}" = "login" ]; then
      : >"$TEST_ROOT/claude-auth"
    elif [ "${1:-}" = "--version" ]; then
      printf "%s\n" "2.1.220"
    fi
  '
  make_fake_command codex '
    printf "codex:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
      [ -f "$TEST_ROOT/codex-auth" ]
    elif [ "${1:-}" = "login" ]; then
      : >"$TEST_ROOT/codex-auth"
    elif [ "${1:-}" = "--version" ]; then
      printf "%s\n" "codex 0.146.0"
    fi
  '
  make_fake_command cursor-agent '
    printf "cursor-agent:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "status" ]; then
      [ -f "$TEST_ROOT/cursor-auth" ]
    elif [ "${1:-}" = "login" ]; then
      : >"$TEST_ROOT/cursor-auth"
    elif [ "${1:-}" = "--version" ]; then
      printf "%s\n" "cursor-agent 1.0"
    fi
  '
  make_fake_command cursor 'printf "%s\n" "Cursor 1.0"'
  make_fake_command open 'printf "open:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"'
}

@test "AI login не запускается без явного да" {
  export VIBE_MAC_TEST_RESPONSE=нет

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  ! grep -E ':(auth login|login)$|open:' "$VIBE_MAC_EVENT_LOG"
  [[ "$output" != *"CANARY_AUTH_OUTPUT"* ]]
}

@test "AI login запускается ровно один раз и raw status не выводится" {
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  [ "$(grep -c '^claude:auth login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^codex:login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^cursor-agent:login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^open:-a Cursor$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [[ "$output" != *"CANARY_AUTH_OUTPUT"* ]]
}

@test "Git defaults заполняются только когда отсутствуют" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  printf '%s\n' 'pull.rebase=merges' >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_RESPONSE=нет
  make_fake_git
  make_fake_gh

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_GIT_STATE" "pull.rebase=merges"
  assert_file_contains "$VIBE_MAC_GIT_STATE" "init.defaultBranch=main"
  assert_file_contains "$VIBE_MAC_GIT_STATE" "push.autoSetupRemote=true"
  [ "$(grep -c '^pull.rebase=' "$VIBE_MAC_GIT_STATE")" -eq 1 ]
}

@test "GitHub login не вызывается без явного да" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_RESPONSE=нет
  make_fake_git
  make_fake_gh

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply

  [ "$status" -eq 0 ]
  ! grep -F "gh:auth login" "$VIBE_MAC_EVENT_LOG"
}

@test "созданные Git defaults получают typed ownership в manifest" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_RESPONSE=нет
  make_fake_git
  make_fake_gh
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract git_defaults.init-default-branch raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"key":"init.defaultBranch"'* ]]
  [[ "$output" == *'"created":true'* ]]
}

make_fake_git() {
  make_fake_command git '
    printf "git:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "--version" ]; then
      printf "%s\n" "git version 2.50.0"
    elif [ "${1:-}" = "config" ] && [ "${2:-}" = "--global" ] && [ "${3:-}" = "--get" ]; then
      line="$(grep -F "$4=" "$VIBE_MAC_GIT_STATE" | tail -n 1)" || exit 1
      printf "%s\n" "${line#*=}"
    elif [ "${1:-}" = "config" ] && [ "${2:-}" = "--global" ]; then
      printf "%s=%s\n" "$3" "$4" >>"$VIBE_MAC_GIT_STATE"
    fi
  '
}

make_fake_gh() {
  make_fake_command gh '
    printf "gh:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
      [ -f "$TEST_ROOT/gh-auth" ]
    elif [ "${1:-}" = "auth" ] && [ "${2:-}" = "login" ]; then
      : >"$TEST_ROOT/gh-auth"
    elif [ "${1:-}" = "--version" ]; then
      printf "%s\n" "gh version 2.0"
    fi
  '
}
