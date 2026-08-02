#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_RELEASE_VERSION=0.1.0-test
  export VIBE_MAC_ARCHIVE_URL=https://example.invalid/vibe-mac.tar.gz
  export VIBE_MAC_ARCHIVE_SOURCE="$TEST_ROOT/release.tar.gz"
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=1
  export VIBE_MAC_CURL_BIN="$TEST_ROOT/fake-bin/curl"
  make_fake_command curl '
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output)
          shift
          target="$1"
          ;;
      esac
      shift
    done
    printf "curl\n" >>"$VIBE_MAC_EVENT_LOG"
    cp "$VIBE_MAC_ARCHIVE_SOURCE" "$target"
  '
  build_good_archive
  refresh_archive_sha
  export VIBE_MAC_SHA256
  VIBE_MAC_SHA256="$(shasum -a 256 "$PROJECT_ROOT/bootstrap.sh" | awk '{print $1}')"
}

build_good_archive() {
  local source bundle entry
  source="$TEST_ROOT/archive-source"
  bundle="$source/vibe-mac-$VIBE_MAC_RELEASE_VERSION"
  if [ -d "$source" ] && [ ! -L "$source" ]; then
    find "$source" -depth -delete
  fi
  mkdir -p "$bundle/config"
  for entry in install verify doctor uninstall; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'if [ -n "${VIBE_MAC_EVENT_LOG:-}" ]; then printf "%s:%s\n" "$0" "$*" >>"$VIBE_MAC_EVENT_LOG"; fi' \
      'exit 0' >"$bundle/$entry.sh"
    chmod +x "$bundle/$entry.sh"
  done
  printf '%s\n' 'VIBE_MAC_VERSION="0.1.0-test"' >"$bundle/config/versions.env"
  /usr/bin/tar -czf "$VIBE_MAC_ARCHIVE_SOURCE" \
    -C "$source" "vibe-mac-$VIBE_MAC_RELEASE_VERSION"
}

refresh_archive_sha() {
  export VIBE_MAC_ARCHIVE_SHA256
  VIBE_MAC_ARCHIVE_SHA256="$(shasum -a 256 "$VIBE_MAC_ARCHIVE_SOURCE" |
    awk '{print $1}')"
}

@test "bootstrap проверяет архив, атомарно ставит release/current/launchers" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 0 ]
  [ -x "$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION/install.sh" ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = "releases/$VIBE_MAC_RELEASE_VERSION" ]
  for launcher in vibe-mac-verify vibe-mac-doctor vibe-mac-uninstall; do
    [ -x "$VIBE_MAC_RUNTIME_ROOT/bin/$launcher" ]
  done
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "curl"
  ! find "$TMPDIR" -maxdepth 1 -name 'vibe-mac.bootstrap.*' | grep -q .
}

@test "bootstrap DRY_RUN не проверяет сеть и ничего не создаёт" {
  : >"$VIBE_MAC_EVENT_LOG"
  before="$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)"

  run env DRY_RUN=1 /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY_RUN"* ]]
  [ "$before" = "$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)" ]
  assert_no_events
}

@test "wrong archive checksum блокирует release и очищает staging" {
  export VIBE_MAC_ARCHIVE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION"
  ! find "$TMPDIR" -maxdepth 1 -name 'vibe-mac.bootstrap.*' | grep -q .
}

@test "wrong bootstrap checksum не вызывает curl" {
  export VIBE_MAC_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  assert_no_events
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT"
}

@test "symlink entry в архиве блокируется до установки" {
  ln -s /tmp "$TEST_ROOT/archive-source/vibe-mac-$VIBE_MAC_RELEASE_VERSION/escape"
  /usr/bin/tar -czf "$VIBE_MAC_ARCHIVE_SOURCE" \
    -C "$TEST_ROOT/archive-source" "vibe-mac-$VIBE_MAC_RELEASE_VERSION"
  refresh_archive_sha

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION"
}

@test "неожиданный top-level и truncated archive блокируются" {
  mv \
    "$TEST_ROOT/archive-source/vibe-mac-$VIBE_MAC_RELEASE_VERSION" \
    "$TEST_ROOT/archive-source/wrong-root"
  /usr/bin/tar -czf "$VIBE_MAC_ARCHIVE_SOURCE" \
    -C "$TEST_ROOT/archive-source" wrong-root
  refresh_archive_sha
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 2 ]

  printf '%s\n' "not an archive" >"$VIBE_MAC_ARCHIVE_SOURCE"
  refresh_archive_sha
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 2 ]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION"
}

@test "существующий release с другим hash не перезаписывается" {
  target="$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION"
  mkdir -p "$target"
  printf '%s\n' canary >"$target/sentinel"
  printf '%s\n' wrong >"$target/.bundle-sha256"

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  assert_file_contains "$target/sentinel" "canary"
}

@test "archive traversal absolute и hardlink entries fail-closed" {
  for kind in traversal absolute hardlink; do
    python3 "$PROJECT_ROOT/tests/helpers/make-malicious-tar.py" \
      "$kind" "$VIBE_MAC_ARCHIVE_SOURCE" "$VIBE_MAC_RELEASE_VERSION"
    refresh_archive_sha

    run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

    [ "$status" -eq 2 ]
    assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION"
    assert_path_absent "$TEST_ROOT/escape"
  done
}

@test "marker не маскирует изменённый existing release tree" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' tampered \
    >>"$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION/install.sh"

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"изменён после установки"* ]]
}

@test "failpoint до current swap сохраняет прежний current" {
  mkdir -p "$VIBE_MAC_RUNTIME_ROOT/releases/old" "$VIBE_MAC_RUNTIME_ROOT/bin"
  ln -s releases/old "$VIBE_MAC_RUNTIME_ROOT/current"
  export VIBE_MAC_TEST_FAILPOINT=before-current-swap

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 1 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = releases/old ]
  ! find "$VIBE_MAC_RUNTIME_ROOT" -maxdepth 1 \
    -name '.current.vibe-mac.*' | grep -q .
}

@test "escaping current и занятый launcher не перезаписываются" {
  mkdir -p "$VIBE_MAC_RUNTIME_ROOT/releases" "$VIBE_MAC_RUNTIME_ROOT/bin"
  ln -s ../../outside "$VIBE_MAC_RUNTIME_ROOT/current"
  printf '%s\n' canary >"$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  assert_file_contains "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" canary
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor"
}

@test "launcher передаёт аргументы и блокирует current escape" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]
  : >"$VIBE_MAC_EVENT_LOG"

  run "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" alpha beta
  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "verify.sh:alpha beta"

  /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  ln -s /tmp "$VIBE_MAC_RUNTIME_ROOT/current"
  run "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"
  [ "$status" -eq 2 ]
}
