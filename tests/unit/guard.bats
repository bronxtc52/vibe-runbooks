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

@test "root блокируется" {
  export DRY_RUN=1
  export VIBE_MAC_TEST_UID=0

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; source "$PROJECT_ROOT/lib/ui.sh"; source "$PROJECT_ROOT/lib/guard.sh"; guard_preflight'

  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}
