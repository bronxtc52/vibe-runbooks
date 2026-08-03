#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
}

@test "tripwire действительно обнаруживает заведомую запись" {
  run /bin/bash "$PROJECT_ROOT/tests/fixtures/tripwire/bad-step.sh"
  [ "$status" -eq 0 ]

  run assert_path_absent "$HOME/should-never-exist-in-dry-run"
  [ "$status" -ne 0 ]
  run assert_no_events
  [ "$status" -ne 0 ]
}

@test "DRY_RUN install не создаёт runtime, log, state или события" {
  before="$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)"
  run env DRY_RUN=1 /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 0 ]
  after="$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT"
  assert_path_absent "$VIBE_MAC_BACKUP_ROOT"
  assert_no_events
}
