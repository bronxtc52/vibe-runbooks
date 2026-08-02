#!/usr/bin/env bash

vibe_test_setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  export PROJECT_ROOT

  TEST_ROOT="$BATS_TEST_TMPDIR/vibe-mac-test"
  export TEST_ROOT
  export HOME="$TEST_ROOT/home"
  export VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
  export VIBE_MAC_BACKUP_ROOT="$HOME/.vibe-mac-backup"
  export VIBE_MAC_TEST_MODE=1
  export VIBE_MAC_TEST_OS=Darwin
  export VIBE_MAC_TEST_ARCH=arm64
  export VIBE_MAC_TEST_MACOS_VERSION=14.7.0
  export VIBE_MAC_TEST_UID=501
  export VIBE_MAC_TEST_FREE_KB=31457280
  export VIBE_MAC_TEST_NETWORK=ok
  export VIBE_MAC_RETRY_DELAYS="0 0"
  export VIBE_MAC_PLUTIL_BIN="$PROJECT_ROOT/tests/helpers/plutil_stub.py"
  export VIBE_MAC_EVENT_LOG="$TEST_ROOT/events.log"
  export TMPDIR="$TEST_ROOT/tmp"

  mkdir -p "$HOME" "$TMPDIR"
  : >"$VIBE_MAC_EVENT_LOG"
}

load_helpers() {
  # shellcheck source=tests/helpers/assertions.bash
  source "$PROJECT_ROOT/tests/helpers/assertions.bash"
  # shellcheck source=tests/helpers/fake-bin.bash
  source "$PROJECT_ROOT/tests/helpers/fake-bin.bash"
}
