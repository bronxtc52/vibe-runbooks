#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export STATE_FILE="$VIBE_MAC_STATE_DIR/progress-unit.json"
  export STATE_TEMPLATE="$PROJECT_ROOT/state/progress-template.json"
}

prepare_release_metadata() {
  local version release launcher
  version="$1"
  release="$VIBE_MAC_RUNTIME_ROOT/releases/$version"
  mkdir -p "$release" "$VIBE_MAC_RUNTIME_ROOT/bin"
  if [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ]; then
    /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  fi
  /bin/ln -s "releases/$version" "$VIBE_MAC_RUNTIME_ROOT/current"
  for launcher in verify doctor uninstall; do
    printf '%s\n' "$version:$launcher" \
      >"$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher"
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
  manifest="$VIBE_MAC_STATE_DIR/manifest-unit.json"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$1"
    [ "$(json_extract_raw "$1" schema_version)" = "1" ]
  ' _ "$manifest"

  [ "$status" -eq 0 ]
  ! grep -F "$USER" "$manifest"
}

@test "plutil stub повторяет raw semantics macOS для composite values" {
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract steps raw -- "$PROJECT_ROOT/state/progress-template.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00-preflight"* ]]
  [[ "$output" != *'"status"'* ]]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.dependency_delta raw -- \
    "$PROJECT_ROOT/state/manifest-template.json"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract steps json -o - -- "$PROJECT_ROOT/state/progress-template.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"00-preflight":{"status":"pending"'* ]]
}

@test "upgrade A в B атомарно обновляет versions и сохраняет previous release" {
  local manifest
  manifest="$VIBE_MAC_MANIFEST_FILE"

  export VIBE_MAC_VERSION=0.1.0-A
  prepare_release_metadata "$VIBE_MAC_VERSION"
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
    manifest_record_release_from_env
  '
  [ "$status" -eq 0 ]

  export VIBE_MAC_VERSION=0.2.0-B
  prepare_release_metadata "$VIBE_MAC_VERSION"
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
    manifest_record_release_from_env
  '
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract installer_version raw -expect string -- "$STATE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = 0.2.0-B ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract installer_version raw -expect string -- "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = 0.2.0-B ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract schema_version raw -expect integer -- "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract releases.current.version raw -expect string -- "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = 0.2.0-B ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract releases.previous.version raw -expect string -- "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = 0.1.0-A ]
}

@test "typed installer_version блокирует state и manifest без частичной записи" {
  local manifest before_state before_manifest
  manifest="$VIBE_MAC_MANIFEST_FILE"
  export VIBE_MAC_VERSION=0.1.0-A

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  [ "$status" -eq 0 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -replace installer_version -bool true "$STATE_FILE"
  [ "$status" -eq 0 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -replace installer_version -bool true "$manifest"
  [ "$status" -eq 0 ]
  before_state="$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')"
  before_manifest="$(shasum -a 256 "$manifest" | awk '{print $1}')"
  export VIBE_MAC_VERSION=0.2.0-B

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
  '
  [ "$status" -eq 2 ]
  [ "$before_state" = "$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')" ]
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  [ "$status" -eq 2 ]
  [ "$before_manifest" = "$(shasum -a 256 "$manifest" | awk '{print $1}')" ]
}

@test "сбой refresh installer_version сохраняет прежние JSON byte-for-byte" {
  local before_state before_manifest
  export VIBE_MAC_VERSION=0.1.0-A
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  [ "$status" -eq 0 ]
  before_state="$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')"
  before_manifest="$(shasum -a 256 \
    "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')"

  export VIBE_MAC_VERSION=0.2.0-B
  export PLUTIL_STUB_FAIL_REPLACE=1
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    state_init "$STATE_TEMPLATE" "$STATE_FILE"
  '
  [ "$status" -eq 2 ]
  [ "$before_state" = "$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')" ]
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  [ "$status" -eq 2 ]
  [ "$before_manifest" = "$(shasum -a 256 \
    "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')" ]
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
    -extract releases.current json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path_kind":"runtime_relative"'* ]]
  [[ "$output" == *'"path":"releases/0.1.0-test"'* ]]
  [[ "$output" == *'"owned":true'* ]]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract launchers.verify json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path":"bin/vibe-mac-verify"'* ]]
}
