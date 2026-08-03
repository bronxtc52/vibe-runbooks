#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_AI_READY=1
  export VIBE_MAC_OPEN_BIN="$TEST_ROOT/fake-bin/open"
  export VIBE_MAC_TEST_CURSOR_APP="$TEST_ROOT/Cursor.app"
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"
  mkdir -p \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/sbin"
  make_auth_app_bundle

  make_fake_command claude '
    printf "claude:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    printf "claude-env:base=%s|browser=%s|config=%s|xdg=%s|cwd=%s\n" \
      "${ANTHROPIC_BASE_URL-unset}" "${BROWSER-unset}" \
      "${CLAUDE_CONFIG_DIR-unset}" "${XDG_CONFIG_HOME-unset}" "$PWD" \
      >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
      printf "%s\n" "token=CANARY_AUTH_OUTPUT"
      [ -f "$TEST_ROOT/claude-auth" ]
    elif [ "${1:-}" = "auth" ] && [ "${2:-}" = "login" ]; then
      [ "${VIBE_MAC_TEST_CLAUDE_LOGIN_FAIL:-0}" != 1 ] || exit 9
      : >"$TEST_ROOT/claude-auth"
    elif [ "${1:-}" = "--version" ]; then
      if [ "$HOME" != /var/empty ] || [ "$TMPDIR" != /var/empty ] ||
        [ "${DO_NOT_TRACK:-}" != 1 ] ||
        [ "${DISABLE_AUTOUPDATER:-}" != 1 ] ||
        [ "${DISABLE_TELEMETRY:-}" != 1 ] ||
        [ "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" != 1 ]; then
        : >"$TEST_ROOT/ai-version-probe-escaped"
      fi
      printf "%s\n" "2.1.220"
    fi
  '
  make_fake_command codex '
    printf "codex:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    printf "codex-env:base=%s|browser=%s|home=%s|xdg=%s|cwd=%s\n" \
      "${OPENAI_BASE_URL-unset}" "${BROWSER-unset}" \
      "${CODEX_HOME-unset}" "${XDG_CONFIG_HOME-unset}" "$PWD" \
      >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
      [ -f "$TEST_ROOT/codex-auth" ]
    elif [ "${1:-}" = "login" ]; then
      : >"$TEST_ROOT/codex-auth"
    elif [ "${1:-}" = "--version" ]; then
      if [ "$HOME" != /var/empty ] || [ "$TMPDIR" != /var/empty ] ||
        [ "${DO_NOT_TRACK:-}" != 1 ] ||
        [ "${DISABLE_AUTOUPDATER:-}" != 1 ] ||
        [ "${DISABLE_TELEMETRY:-}" != 1 ]; then
        : >"$TEST_ROOT/ai-version-probe-escaped"
      fi
      printf "%s\n" "codex 0.146.0"
    fi
  '
  make_fake_command cursor-agent '
    printf "cursor-agent:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    printf "cursor-env:base=%s|browser=%s|xdg=%s|cwd=%s\n" \
      "${CURSOR_API_URL-unset}" "${BROWSER-unset}" \
      "${XDG_CONFIG_HOME-unset}" "$PWD" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "status" ]; then
      [ -f "$TEST_ROOT/cursor-auth" ]
    elif [ "${1:-}" = "login" ]; then
      : >"$TEST_ROOT/cursor-auth"
    elif [ "${1:-}" = "--version" ]; then
      if [ "$HOME" != /var/empty ] || [ "$TMPDIR" != /var/empty ] ||
        [ "${DO_NOT_TRACK:-}" != 1 ] ||
        [ "${DISABLE_AUTOUPDATER:-}" != 1 ] ||
        [ "${DISABLE_TELEMETRY:-}" != 1 ]; then
        : >"$TEST_ROOT/ai-version-probe-escaped"
      fi
      printf "%s\n" "cursor-agent 1.0"
    fi
  '
  make_fake_command open '
    printf "open:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    printf "open-env:browser=%s|cwd=%s\n" "${BROWSER-unset}" "$PWD" \
      >>"$VIBE_MAC_EVENT_LOG"
  '
  for command_name in claude codex cursor-agent; do
    /bin/cp "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
}

make_auth_app_bundle() {
  /bin/mkdir -p "$VIBE_MAC_TEST_CURSOR_APP/Contents/MacOS"
  printf '%s\n' \
    '{"CFBundleExecutable":"Cursor","CFBundleIdentifier":"com.example.Cursor"}' \
    >"$VIBE_MAC_TEST_CURSOR_APP/Contents/Info.plist"
  printf '%s\n' '#!/bin/bash' 'exit 0' \
    >"$VIBE_MAC_TEST_CURSOR_APP/Contents/MacOS/Cursor"
  /bin/chmod 0700 "$VIBE_MAC_TEST_CURSOR_APP/Contents/MacOS/Cursor"
}

@test "AI login не запускается без явного да" {
  export VIBE_MAC_TEST_RESPONSE=нет

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  ! grep -E ':(auth login|login)$|open:' "$VIBE_MAC_EVENT_LOG"
  [[ "$output" != *"CANARY_AUTH_OUTPUT"* ]]
  [[ "$output" == *"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/claude auth login"* ]]
  [[ "$output" == *"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/codex login"* ]]
  [[ "$output" == *"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/cursor-agent login"* ]]
  [[ "$output" == *"/usr/bin/open /Applications/Cursor.app"* ]]
}

@test "AI login запускается ровно один раз и raw status не выводится" {
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  [ "$(grep -c '^claude:auth login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^codex:login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^cursor-agent:login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -Fxc "open:$VIBE_MAC_TEST_CURSOR_APP" "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [[ "$output" != *"CANARY_AUTH_OUTPUT"* ]]
}

@test "Cursor login открывает exact проверенный app path, а не LaunchServices name" {
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "open:$VIBE_MAC_TEST_CURSOR_APP"
  run /usr/bin/grep -Fq "open:-a Cursor" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "AI auth игнорирует endpoint browser и config overrides" {
  safe_cwd="$(cd /var/empty && pwd -P)"
  export VIBE_MAC_TEST_RESPONSE=да
  export ANTHROPIC_BASE_URL=https://hostile.invalid/anthropic
  export OPENAI_BASE_URL=https://hostile.invalid/openai
  export CURSOR_API_URL=https://hostile.invalid/cursor
  export BROWSER="$TEST_ROOT/hostile-browser"
  export CLAUDE_CONFIG_DIR="$TEST_ROOT/hostile-claude"
  export CODEX_HOME="$TEST_ROOT/hostile-codex"
  export XDG_CONFIG_HOME="$TEST_ROOT/hostile-xdg"

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "claude-env:base=unset|browser=unset|config=unset|xdg=unset|cwd=$safe_cwd"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "codex-env:base=unset|browser=unset|home=unset|xdg=unset|cwd=$safe_cwd"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "cursor-env:base=unset|browser=unset|xdg=unset|cwd=$safe_cwd"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "open-env:browser=unset|cwd=$safe_cwd"
  run /usr/bin/grep -Fq "hostile.invalid" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/hostile-browser" ]
  [ ! -e "$TEST_ROOT/hostile-claude" ]
  [ ! -e "$TEST_ROOT/hostile-codex" ]
  [ ! -e "$TEST_ROOT/hostile-xdg" ]
}

@test "сбой необязательного AI login не останавливает технический шаг" {
  export VIBE_MAC_TEST_RESPONSE=да
  export VIBE_MAC_TEST_CLAUDE_LOGIN_FAIL=1

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"Вход Claude не завершён. Повтори:"* ]]
  [[ "$output" == *"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/claude auth login"* ]]
  [ "$(grep -c '^codex:login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^cursor-agent:login$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
}

@test "AI step игнорирует PATH trojan и запускает exact Homebrew binaries" {
  local command_name trusted
  for command_name in claude codex cursor-agent; do
    trusted="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
    /bin/unlink "$trusted"
    /bin/cp "$TEST_ROOT/fake-bin/$command_name" "$trusted"
  done
  make_fake_command claude '
    printf "%s\n" "trojan:claude:$*" >>"$VIBE_MAC_EVENT_LOG"
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/claude" "$@"
  '
  make_fake_command codex '
    printf "%s\n" "trojan:codex:$*" >>"$VIBE_MAC_EVENT_LOG"
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/codex" "$@"
  '
  make_fake_command cursor-agent '
    printf "%s\n" "trojan:cursor-agent:$*" >>"$VIBE_MAC_EVENT_LOG"
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/cursor-agent" "$@"
  '
  export VIBE_MAC_TEST_RESPONSE=нет

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" apply

  [ "$status" -eq 0 ]
  run /usr/bin/grep -Fq 'trojan:' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "AI step блокирует executable symlink за пределы Homebrew prefix" {
  trusted="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/claude"
  /bin/unlink "$trusted"
  /bin/ln -s "$TEST_ROOT/fake-bin/claude" "$trusted"

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" verify

  [ "$status" -eq 2 ]
  assert_no_events
}

@test "AI step принимает Homebrew symlink только внутрь Cellar" {
  cellar="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/claude/1/bin"
  /bin/mkdir -p "$cellar"
  /bin/mv "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/claude" \
    "$cellar/claude"
  /bin/ln -s ../Cellar/claude/1/bin/claude \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/claude"

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" verify

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "claude:--version"
}

@test "AI auth блокирует symlink config и не исполняет CLI" {
  /bin/mkdir -p "$TEST_ROOT/outside-claude"
  /bin/ln -s "$TEST_ROOT/outside-claude" "$HOME/.claude"

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" verify

  [ "$status" -eq 2 ]
  assert_no_events
}

@test "AI verify не принимает пустой Cursor app bundle" {
  /bin/mv "$VIBE_MAC_TEST_CURSOR_APP" "$TEST_ROOT/valid-Cursor.app"
  /bin/mkdir "$VIBE_MAC_TEST_CURSOR_APP"

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" verify

  [ "$status" -eq 1 ]
  assert_no_events
}

@test "AI verify в install DRY_RUN не запускает CLI" {
  export DRY_RUN=1

  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" verify

  [ "$status" -eq 0 ]
  [ ! -s "$VIBE_MAC_EVENT_LOG" ]
}

@test "AI version probes не используют writable HOME и отключают updater telemetry" {
  run /bin/bash "$PROJECT_ROOT/steps/60-ai-agents.sh" verify

  [ "$status" -eq 0 ]
  assert_path_absent "$TEST_ROOT/ai-version-probe-escaped"
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

@test "сбой необязательного GitHub login не останавливает технический шаг" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_RESPONSE=да
  export VIBE_MAC_TEST_GH_LOGIN_FAIL=1
  export VIBE_MAC_TEST_GIT_NAME="Test User"
  export VIBE_MAC_TEST_GIT_EMAIL="test@example.invalid"
  make_fake_git
  make_fake_gh

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"Вход GitHub не завершён. Повтори:"* ]]
  [[ "$output" == *"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/gh auth login --hostname github.com --web --git-protocol https"* ]]
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
    -extract git_defaults.init-default-branch json -o - -- \
    "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"key":"init.defaultBranch"'* ]]
  [[ "$output" == *'"created":true'* ]]
}

make_fake_git() {
  make_fake_command git '
    printf "git:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    printf "git-env:config_global=%s|dir=%s|work_tree=%s|template=%s|exec_path=%s|cwd=%s\n" \
      "${GIT_CONFIG_GLOBAL-unset}" \
      "${GIT_DIR-unset}" \
      "${GIT_WORK_TREE-unset}" \
      "${GIT_TEMPLATE_DIR-unset}" \
      "${GIT_EXEC_PATH-unset}" "$PWD" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "--version" ]; then
      printf "%s\n" "git version 2.50.0"
    elif [ "${1:-}" = "config" ] && [ "${2:-}" = "--global" ] && [ "${3:-}" = "--get" ]; then
      line="$(grep -F "$4=" "$VIBE_MAC_GIT_STATE" | tail -n 1)" || exit 1
      printf "%s\n" "${line#*=}"
    elif [ "${1:-}" = "config" ] && [ "${2:-}" = "--global" ]; then
      printf "%s=%s\n" "$3" "$4" >>"$VIBE_MAC_GIT_STATE"
    fi
  '
  /bin/cp "$TEST_ROOT/fake-bin/git" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/git"
}

make_fake_gh() {
  make_fake_command gh '
    printf "gh:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    printf "gh-env:host=%s|config=%s|token=%s|cwd=%s\n" \
      "${GH_HOST-unset}" \
      "${GH_CONFIG_DIR-unset}" \
      "${GH_TOKEN-unset}" "$PWD" >>"$VIBE_MAC_EVENT_LOG"
    if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
      [ -f "$TEST_ROOT/gh-auth" ]
    elif [ "${1:-}" = "auth" ] && [ "${2:-}" = "login" ]; then
      [ "${VIBE_MAC_TEST_GH_LOGIN_FAIL:-0}" != 1 ] || exit 9
      : >"$TEST_ROOT/gh-auth"
    elif [ "${1:-}" = "--version" ]; then
      if [ "$HOME" != /var/empty ] || [ "$TMPDIR" != /var/empty ] ||
        [ "${GH_CONFIG_DIR:-}" != /var/empty ] ||
        [ "${GH_TELEMETRY:-}" != disabled ] ||
        [ "${DO_NOT_TRACK:-}" != 1 ]; then
        : >"$TEST_ROOT/gh-version-probe-escaped"
      fi
      printf "%s\n" "gh version 2.0"
    fi
  '
  /bin/cp "$TEST_ROOT/fake-bin/gh" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/gh"
}

@test "gh version probe не создаёт telemetry state в HOME" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_RESPONSE=нет
  make_fake_git
  make_fake_gh

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" verify

  [ "$status" -eq 0 ]
  assert_path_absent "$TEST_ROOT/gh-version-probe-escaped"
}

@test "Git и GitHub login игнорируют hostile env и фиксируют github.com" {
  safe_cwd="$(cd /var/empty && pwd -P)"
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_RESPONSE=да
  export VIBE_MAC_TEST_GIT_NAME="Test User"
  export VIBE_MAC_TEST_GIT_EMAIL="test@example.invalid"
  export GIT_CONFIG_GLOBAL="$TEST_ROOT/attacker.gitconfig"
  export GIT_DIR="$TEST_ROOT/attacker.git"
  export GIT_WORK_TREE="$TEST_ROOT/attacker-worktree"
  export GIT_TEMPLATE_DIR="$TEST_ROOT/attacker-template"
  export GIT_EXEC_PATH="$TEST_ROOT/attacker-exec"
  export GH_HOST=hostile.invalid
  export GH_CONFIG_DIR="$TEST_ROOT/attacker-gh"
  export GH_TOKEN=hostile-test-value
  make_fake_git
  make_fake_gh

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "git-env:config_global=unset|dir=unset|work_tree=unset|template=unset|exec_path=unset"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "gh:auth login --hostname github.com --web --git-protocol https"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "gh-env:host=github.com|config=$HOME/.config/gh|token=unset"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "cwd=$safe_cwd"
  run /usr/bin/grep -Fq "hostile.invalid" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/attacker.gitconfig" ]
  [ ! -e "$TEST_ROOT/attacker-gh" ]
}

@test "GitHub auth блокирует symlink config за пределы HOME" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  make_fake_git
  make_fake_gh
  /bin/mkdir -p "$HOME/.config" "$TEST_ROOT/outside-gh"
  /bin/ln -s "$TEST_ROOT/outside-gh" "$HOME/.config/gh"

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply

  [ "$status" -eq 2 ]
  run /usr/bin/grep -Fq '^gh:' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "GitHub step блокирует executable symlink наружу" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  make_fake_git
  make_fake_gh
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/gh"
  /bin/ln -s "$TEST_ROOT/fake-bin/gh" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/gh"

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply

  [ "$status" -eq 2 ]
  assert_no_events
}

@test "GitHub step принимает Homebrew links внутрь Cellar" {
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  : >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_RESPONSE=нет
  make_fake_git
  make_fake_gh
  for command_name in git gh; do
    cellar="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/$command_name/1/bin"
    /bin/mkdir -p "$cellar"
    /bin/mv "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name" \
      "$cellar/$command_name"
    /bin/ln -s "../Cellar/$command_name/1/bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done

  run /bin/bash "$PROJECT_ROOT/steps/70-git-github.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "git:--version"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "gh:--version"
}
