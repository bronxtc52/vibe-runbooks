#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export STATE_FILE="$TEST_ROOT/state/progress.json"
  export STATE_TEMPLATE="$PROJECT_ROOT/state/progress-template.json"
}

@test "state создаётся из валидного шаблона и меняется атомарно" {
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
    [ "$(state_get_status "$STATE_FILE" "00-preflight")" = "pending" ]
    state_mark_complete "$STATE_FILE" "00-preflight" "2026-08-02T00:00:00Z"
    [ "$(state_get_status "$STATE_FILE" "00-preflight")" = "completed" ]
  '

  [ "$status" -eq 0 ]
  [ -f "$STATE_FILE" ]
}

@test "ошибка plutil не повреждает прежний state" {
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
  '
  [ "$status" -eq 0 ]
  before="$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')"

  export PLUTIL_STUB_FAIL_REPLACE=1
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_mark_complete "$STATE_FILE" "00-preflight" "2026-08-02T00:00:00Z"
  '

  [ "$status" -ne 0 ]
  after="$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "manifest создаётся с известной schema без персональных данных" {
  manifest="$TEST_ROOT/state/manifest.json"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$1"
    [ "$(json_extract_raw "$1" schema_version)" = "1" ]
  ' _ "$manifest"

  [ "$status" -eq 0 ]
  ! grep -F "$USER" "$manifest"
}

@test "bootstrap metadata записывается typed release ownership" {
  version=0.1.0-test
  release="$VIBE_MAC_RUNTIME_ROOT/releases/$version"
  mkdir -p "$release" "$VIBE_MAC_RUNTIME_ROOT/bin"
  ln -s "releases/$version" "$VIBE_MAC_RUNTIME_ROOT/current"
  for launcher in verify doctor uninstall; do
    printf '%s\n' "$launcher" >"$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher"
  done
  export VIBE_MAC_ROOT="$release"
  export VIBE_MAC_RELEASE_VERSION="$version"
  export VIBE_MAC_RELEASE_ARCHIVE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export VIBE_MAC_RELEASE_TREE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export VIBE_MAC_LAUNCHER_VERIFY_SHA256
  export VIBE_MAC_LAUNCHER_DOCTOR_SHA256
  export VIBE_MAC_LAUNCHER_UNINSTALL_SHA256
  VIBE_MAC_LAUNCHER_VERIFY_SHA256="$(shasum -a 256 \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" | awk '{print $1}')"
  VIBE_MAC_LAUNCHER_DOCTOR_SHA256="$(shasum -a 256 \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor" | awk '{print $1}')"
  VIBE_MAC_LAUNCHER_UNINSTALL_SHA256="$(shasum -a 256 \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-uninstall" | awk '{print $1}')"

  run /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
    manifest_record_release_from_env
  '

  [ "$status" -eq 0 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract releases.current raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path_kind":"runtime_relative"'* ]]
  [[ "$output" == *'"path":"releases/0.1.0-test"'* ]]
  [[ "$output" == *'"owned":true'* ]]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract launchers.verify raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path":"bin/vibe-mac-verify"'* ]]
}
