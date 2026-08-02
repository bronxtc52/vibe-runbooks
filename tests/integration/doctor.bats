#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    init_runtime_layout
    state_init "$PROJECT_ROOT/state/progress-template.json" "$VIBE_MAC_STATE_FILE"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  mkdir -p "$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test"
  ln -s releases/0.1.0-test "$VIBE_MAC_RUNTIME_ROOT/current"
}

tree_snapshot() {
  {
    find "$TEST_ROOT" -mindepth 1 -type f -exec shasum -a 256 {} \; |
      LC_ALL=C sort
    find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort
  }
}

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

make_lock() {
  local pid
  pid="$1"
  mkdir -p "$VIBE_MAC_LOCK_DIR"
  printf '%s\n' "$pid" >"$VIBE_MAC_LOCK_DIR/pid"
  printf '%s\n' "0.1.0-dev" >"$VIBE_MAC_LOCK_DIR/version"
  printf '%s\n' "2026-08-02T00:00:00Z" >"$VIBE_MAC_LOCK_DIR/started_at"
}

@test "doctor без флагов диагностирует stale lock без единой записи" {
  make_lock 99999999
  before="$(tree_snapshot)"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"stale lock"* ]]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
  [ "$before" = "$(tree_snapshot)" ]
  assert_no_events
}

@test "doctor --repair без подтверждения ничего не исправляет" {
  make_lock 99999999
  chmod 0755 "$VIBE_MAC_RUNTIME_ROOT"
  export VIBE_MAC_TEST_RESPONSE=нет

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 1 ]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
  [ "$(mode_of "$VIBE_MAC_RUNTIME_ROOT")" = 755 ]
}

@test "doctor --repair чинит только stale lock и точный mode после да" {
  make_lock 99999999
  chmod 0755 "$VIBE_MAC_RUNTIME_ROOT"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 0 ]
  assert_path_absent "$VIBE_MAC_LOCK_DIR"
  [ "$(mode_of "$VIBE_MAC_RUNTIME_ROOT")" = 700 ]
}

@test "doctor никогда не удаляет lock живого процесса" {
  make_lock "$$"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 1 ]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
  [[ "$output" == *"активный lock"* ]]
}

@test "повреждённый manifest даёт exit 2 и остаётся byte-for-byte" {
  printf '%s\n' '{broken' >"$VIBE_MAC_MANIFEST_FILE"
  before="$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [ "$before" = "$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')" ]
}

@test "extra lock entry делает repair fail-closed без частичного удаления" {
  make_lock 99999999
  printf '%s\n' unexpected >"$VIBE_MAC_LOCK_DIR/extra"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 2 ]
  [ -f "$VIBE_MAC_LOCK_DIR/pid" ]
  [ -f "$VIBE_MAC_LOCK_DIR/extra" ]
}

@test "corrupt manifest блокирует удаление отдельно валидного stale lock" {
  make_lock 99999999
  printf '%s\n' '{broken' >"$VIBE_MAC_MANIFEST_FILE"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 2 ]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
}

@test "backup hash mismatch является integrity blocker" {
  mkdir -p "$HOME/.config/vibe-mac"
  printf '%s\n' aliases >"$HOME/.config/vibe-mac/aliases.zsh"
  applied_sha="$(shasum -a 256 "$HOME/.config/vibe-mac/aliases.zsh" |
    awk '{print $1}')"
  export applied_sha
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    backup_file_once "$HOME/.config/vibe-mac/aliases.zsh" aliases-zsh >/dev/null
    manifest_record_file \
      aliases .config/vibe-mac/aliases.zsh owned_file "" true true \
      "$applied_sha" aliases-zsh
  '
  printf '%s\n' tampered \
    >>"$VIBE_MAC_BACKUP_ROOT/test-install/aliases-zsh.before"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"backup evidence"* ]]
}
