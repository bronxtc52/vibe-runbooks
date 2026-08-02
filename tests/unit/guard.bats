#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
}

@test "поддерживаемый arm64 macOS 14 проходит preflight в DRY_RUN" {
  export DRY_RUN=1

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; source "$PROJECT_ROOT/lib/ui.sh"; source "$PROJECT_ROOT/lib/guard.sh"; guard_preflight'

  [ "$status" -eq 0 ]
}

@test "macOS 13 блокируется до записи" {
  export DRY_RUN=1
  export VIBE_MAC_TEST_MACOS_VERSION=13.7.8

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; source "$PROJECT_ROOT/lib/ui.sh"; source "$PROJECT_ROOT/lib/guard.sh"; guard_preflight'

  [ "$status" -ne 0 ]
  [[ "$output" == *"macOS 14"* ]]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT"
}

@test "Intel без opt-in блокируется" {
  export DRY_RUN=1
  export VIBE_MAC_TEST_ARCH=x86_64

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; source "$PROJECT_ROOT/lib/ui.sh"; source "$PROJECT_ROOT/lib/guard.sh"; guard_preflight'

  [ "$status" -ne 0 ]
  [[ "$output" == *"Intel"* ]]
}

@test "Intel opt-in DRY_RUN проходит без typed подтверждения" {
  export DRY_RUN=1
  export VIBE_MAC_TEST_ARCH=x86_64
  export ALLOW_UNSUPPORTED_INTEL=1
  export VIBE_MAC_TEST_RESPONSE=wrong

  run /bin/bash -c 'source "$PROJECT_ROOT/lib/util.sh"; source "$PROJECT_ROOT/lib/ui.sh"; source "$PROJECT_ROOT/lib/guard.sh"; guard_preflight'

  [ "$status" -eq 0 ]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT"
}

@test "root блокируется" {
  export DRY_RUN=1
  export VIBE_MAC_TEST_UID=0

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; source "$PROJECT_ROOT/lib/ui.sh"; source "$PROJECT_ROOT/lib/guard.sh"; guard_preflight'

  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}

@test "network preflight игнорирует hostile curl окружение и пользовательский config" {
  source "$PROJECT_ROOT/lib/util.sh"
  source "$PROJECT_ROOT/lib/ui.sh"
  source "$PROJECT_ROOT/lib/guard.sh"
  DRY_RUN=0
  make_fake_command guard-curl '
    printf "%s\n" \
      "guard-curl:args=$*|proxy=${HTTPS_PROXY:-unset}|bash_env=${BASH_ENV:-unset}|curl_home=${CURL_HOME:-unset}" \
      >>"$VIBE_MAC_EVENT_LOG"
    [ "${1:-}" = -q ]
  '
  export VIBE_MAC_CURL_BIN="$TEST_ROOT/fake-bin/guard-curl"
  export HTTPS_PROXY=https://hostile.invalid
  export BASH_ENV="$TEST_ROOT/hostile-bash-env"
  printf '%s\n' 'printf hostile >"$TEST_ROOT/bash-env-ran"' >"$BASH_ENV"
  printf '%s\n' 'printf hostile >"$TEST_ROOT/curlrc-ran"' >"$HOME/.curlrc"

  run guard_network

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    'guard-curl:args=-q --proto =https --tlsv1.2 --fail --location --silent --show-error --connect-timeout 10 --max-time 20 --output /dev/null https://github.com/|proxy=unset|bash_env=unset|curl_home=/var/empty'
  assert_path_absent "$TEST_ROOT/bash-env-ran"
  assert_path_absent "$TEST_ROOT/curlrc-ran"
}
