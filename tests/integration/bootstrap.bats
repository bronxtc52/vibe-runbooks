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
      'if [ "${VIBE_MAC_TEST_INSTALL_MUTATE_METADATA:-0}" = 1 ] && [ "${0##*/}" = install.sh ]; then' \
      '  state_dir="$VIBE_MAC_RUNTIME_ROOT/state"' \
      '  manifest_tmp="$state_dir/.manifest.resume-test.$$"' \
      '  progress_tmp="$state_dir/.progress.resume-test.$$"' \
      '  mkdir -p "$state_dir"' \
      '  umask 077' \
      '  printf "%s\n" "{\"schema_version\":1,\"installer_version\":\"$VIBE_MAC_RELEASE_VERSION\",\"install_id\":\"resume-test\",\"releases\":{\"current\":{\"version\":\"$VIBE_MAC_RELEASE_VERSION\",\"path_kind\":\"runtime_relative\",\"path\":\"releases/$VIBE_MAC_RELEASE_VERSION\",\"owned\":true}},\"current_link\":{\"path_kind\":\"runtime_relative\",\"path\":\"current\",\"target\":\"releases/$VIBE_MAC_RELEASE_VERSION\",\"owned\":true}}" >"$manifest_tmp"' \
      '  printf "%s\n" "{\"schema_version\":1,\"installer_version\":\"$VIBE_MAC_RELEASE_VERSION\",\"last_run_id\":\"resume-test\",\"steps\":{\"00-preflight\":{\"status\":\"completed\",\"completed_at\":\"2026-08-02T00:00:00Z\"},\"10-xcode-clt\":{\"status\":\"running\",\"completed_at\":\"\"}}}" >"$progress_tmp"' \
      '  /bin/mv -f "$manifest_tmp" "$state_dir/manifest.json"' \
      '  /bin/mv -f "$progress_tmp" "$state_dir/progress.json"' \
      'fi' \
      'if [ "${VIBE_MAC_TEST_INSTALL_MUTATE_PROGRESS_ONLY:-0}" = 1 ] && [ "${0##*/}" = install.sh ]; then' \
      '  state_dir="$VIBE_MAC_RUNTIME_ROOT/state"' \
      '  progress_tmp="$state_dir/.progress.partial-test.$$"' \
      '  mkdir -p "$state_dir"' \
      '  printf "%s\n" "{\"schema_version\":1,\"installer_version\":\"$VIBE_MAC_RELEASE_VERSION\",\"last_run_id\":\"partial-test\",\"steps\":{\"00-preflight\":{\"status\":\"running\",\"completed_at\":\"\"}}}" >"$progress_tmp"' \
      '  /bin/mv -f "$progress_tmp" "$state_dir/progress.json"' \
      'fi' \
      'if [ "${VIBE_MAC_TEST_INSTALL_MUTATE_INVALID_LINKAGE:-0}" = 1 ] && [ "${0##*/}" = install.sh ]; then' \
      '  state_dir="$VIBE_MAC_RUNTIME_ROOT/state"' \
      '  manifest_tmp="$state_dir/.manifest.invalid-linkage-test.$$"' \
      '  progress_tmp="$state_dir/.progress.invalid-linkage-test.$$"' \
      '  mkdir -p "$state_dir"' \
      '  printf "%s\n" "{\"schema_version\":1,\"installer_version\":\"$VIBE_MAC_RELEASE_VERSION\",\"install_id\":\"invalid-linkage-test\",\"releases\":{\"current\":{\"version\":\"$VIBE_MAC_RELEASE_VERSION\",\"path_kind\":\"runtime_relative\",\"path\":\"releases/$VIBE_MAC_RELEASE_VERSION\",\"owned\":true}},\"current_link\":{\"path_kind\":\"runtime_relative\",\"path\":\"current\",\"target\":\"releases/old\",\"owned\":true}}" >"$manifest_tmp"' \
      '  printf "%s\n" "{\"schema_version\":1,\"installer_version\":\"$VIBE_MAC_RELEASE_VERSION\",\"last_run_id\":\"invalid-linkage-test\",\"steps\":{\"00-preflight\":{\"status\":\"running\",\"completed_at\":\"\"}}}" >"$progress_tmp"' \
      '  /bin/mv -f "$manifest_tmp" "$state_dir/manifest.json"' \
      '  /bin/mv -f "$progress_tmp" "$state_dir/progress.json"' \
      'fi' \
      'case "$0" in */install.sh) [ "${VIBE_MAC_TEST_INSTALL_FAIL:-0}" != 1 ] || exit 7 ;; esac' \
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

seed_previous_release_state() {
  mkdir -p \
    "$VIBE_MAC_RUNTIME_ROOT/releases/old" \
    "$VIBE_MAC_RUNTIME_ROOT/bin" \
    "$VIBE_MAC_RUNTIME_ROOT/state"
  ln -s releases/old "$VIBE_MAC_RUNTIME_ROOT/current"
  printf '%s\n' \
    '{"schema_version":1,"installer_version":"old","install_id":"existing","releases":{"current":{"version":"old","path_kind":"runtime_relative","path":"releases/old","owned":true}},"current_link":{"path_kind":"runtime_relative","path":"current","target":"releases/old","owned":true}}' \
    >"$VIBE_MAC_RUNTIME_ROOT/state/manifest.json"
  printf '%s\n' \
    '{"schema_version":1,"installer_version":"old","last_run_id":"old-run","steps":{"00-preflight":{"status":"pending","completed_at":""}}}' \
    >"$VIBE_MAC_RUNTIME_ROOT/state/progress.json"
}

use_convert_only_plutil_adapter() {
  make_fake_command plutil-convert-only '
    case "$1" in
      -lint) exit 91 ;;
      -convert|-extract)
        exec "$PROJECT_ROOT/tests/helpers/plutil_stub.py" "$@"
        ;;
      *) exit 92 ;;
    esac
  '
  export VIBE_MAC_PLUTIL_BIN="$TEST_ROOT/fake-bin/plutil-convert-only"
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

@test "symlink HOME блокирует bootstrap до сети и runtime writes" {
  real_home="$TEST_ROOT/bootstrap-real-home"
  linked_home="$TEST_ROOT/bootstrap-linked-home"
  mkdir -p "$real_home"
  ln -s "$real_home" "$linked_home"
  export HOME="$linked_home"
  export VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  assert_no_events
  assert_path_absent "$real_home/.vibe-mac"
  ! find "$TMPDIR" -maxdepth 1 -name 'vibe-mac.bootstrap.*' | grep -q .
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

@test "nested bundle marker name входит в release fingerprint" {
  mkdir -p \
    "$TEST_ROOT/archive-source/vibe-mac-$VIBE_MAC_RELEASE_VERSION/nested"
  printf '%s\n' tracked > \
    "$TEST_ROOT/archive-source/vibe-mac-$VIBE_MAC_RELEASE_VERSION/nested/.bundle-tree-sha256"
  /usr/bin/tar -czf "$VIBE_MAC_ARCHIVE_SOURCE" \
    -C "$TEST_ROOT/archive-source" "vibe-mac-$VIBE_MAC_RELEASE_VERSION"
  refresh_archive_sha

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]

  printf '%s\n' tampered > \
    "$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION/nested/.bundle-tree-sha256"
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"существующий release изменён"* ]]
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

@test "успешное обновление атомарно заменяет существующий current symlink" {
  mkdir -p "$VIBE_MAC_RUNTIME_ROOT/releases/old" "$VIBE_MAC_RUNTIME_ROOT/bin"
  ln -s releases/old "$VIBE_MAC_RUNTIME_ROOT/current"

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 0 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = "releases/$VIBE_MAC_RELEASE_VERSION" ]
  ! find "$VIBE_MAC_RUNTIME_ROOT/releases/old" -mindepth 1 -print | grep -q .
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

@test "ошибка нового install откатывает current на предыдущий release" {
  mkdir -p "$VIBE_MAC_RUNTIME_ROOT/releases/old" "$VIBE_MAC_RUNTIME_ROOT/bin"
  ln -s releases/old "$VIBE_MAC_RUNTIME_ROOT/current"
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=0
  export VIBE_MAC_TEST_INSTALL_FAIL=1

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 7 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = releases/old ]
  [ -d "$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION" ]
}

@test "после progress/manifest failure current остаётся новым и metadata согласованы" {
  mkdir -p \
    "$VIBE_MAC_RUNTIME_ROOT/releases/old" \
    "$VIBE_MAC_RUNTIME_ROOT/bin" \
    "$VIBE_MAC_RUNTIME_ROOT/state"
  ln -s releases/old "$VIBE_MAC_RUNTIME_ROOT/current"
  printf '%s\n' \
    '{"schema_version":1,"installer_version":"old","install_id":"existing","releases":{"current":{"version":"old","path_kind":"runtime_relative","path":"releases/old","owned":true}},"current_link":{"path_kind":"runtime_relative","path":"current","target":"releases/old","owned":true}}' \
    >"$VIBE_MAC_RUNTIME_ROOT/state/manifest.json"
  printf '%s\n' \
    '{"schema_version":1,"installer_version":"old","last_run_id":"old-run","steps":{"00-preflight":{"status":"pending","completed_at":""}}}' \
    >"$VIBE_MAC_RUNTIME_ROOT/state/progress.json"
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=0
  export VIBE_MAC_TEST_INSTALL_MUTATE_METADATA=1
  export VIBE_MAC_TEST_INSTALL_FAIL=1

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 7 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = \
    "releases/$VIBE_MAC_RELEASE_VERSION" ]
  bootstrap_output="$output"
  run python3 -c '
import json
import sys

manifest_path, progress_path, current_target, expected_version = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
with open(progress_path, encoding="utf-8") as handle:
    progress = json.load(handle)

release = manifest["releases"]["current"]
assert release["version"] == expected_version
assert release["path"] == current_target
assert manifest["current_link"]["target"] == current_target
assert progress["installer_version"] == expected_version
assert progress["last_run_id"] == "resume-test"
assert progress["steps"]["00-preflight"]["status"] == "completed"
assert progress["steps"]["10-xcode-clt"]["status"] == "running"
' \
    "$VIBE_MAC_RUNTIME_ROOT/state/manifest.json" \
    "$VIBE_MAC_RUNTIME_ROOT/state/progress.json" \
    "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" \
    "$VIBE_MAC_RELEASE_VERSION"
  [ "$status" -eq 0 ]
  [[ "$bootstrap_output" == *"для безопасного продолжения"* ]]
}

@test "valid active linkage проходит через convert-only plutil adapter" {
  seed_previous_release_state
  use_convert_only_plutil_adapter
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=0
  export VIBE_MAC_TEST_INSTALL_MUTATE_METADATA=1
  export VIBE_MAC_TEST_INSTALL_FAIL=1

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 7 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = \
    "releases/$VIBE_MAC_RELEASE_VERSION" ]
  [[ "$output" == *"для безопасного продолжения"* ]]
}

@test "real macOS plutil сохраняет current при valid JSON active linkage" {
  [ "$(uname -s)" = Darwin ] || skip "только реальный macOS plutil"
  [ -x /usr/bin/plutil ] || skip "/usr/bin/plutil отсутствует"
  seed_previous_release_state
  if /usr/bin/plutil -lint \
    "$VIBE_MAC_RUNTIME_ROOT/state/manifest.json" >/dev/null 2>&1; then
    skip "этот plutil уже принимает JSON через -lint"
  fi
  manifest_sha_before="$(shasum -a 256 \
    "$VIBE_MAC_RUNTIME_ROOT/state/manifest.json" | awk '{print $1}')"
  /usr/bin/plutil -convert json -o /dev/null -- \
    "$VIBE_MAC_RUNTIME_ROOT/state/manifest.json" >/dev/null 2>&1 ||
    skip "этот plutil не поддерживает read-only JSON convert"
  [ "$(shasum -a 256 "$VIBE_MAC_RUNTIME_ROOT/state/manifest.json" | \
    awk '{print $1}')" = "$manifest_sha_before" ]
  export VIBE_MAC_PLUTIL_BIN=/usr/bin/plutil
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=0
  export VIBE_MAC_TEST_INSTALL_MUTATE_METADATA=1
  export VIBE_MAC_TEST_INSTALL_FAIL=1

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 7 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = \
    "releases/$VIBE_MAC_RELEASE_VERSION" ]
  [[ "$output" == *"для безопасного продолжения"* ]]
}

@test "progress-only failure не оставляет current без manifest linkage" {
  mkdir -p \
    "$VIBE_MAC_RUNTIME_ROOT/releases/old" \
    "$VIBE_MAC_RUNTIME_ROOT/bin" \
    "$VIBE_MAC_RUNTIME_ROOT/state"
  ln -s releases/old "$VIBE_MAC_RUNTIME_ROOT/current"
  printf '%s\n' \
    '{"schema_version":1,"installer_version":"old","install_id":"existing","releases":{"current":{"version":"old","path_kind":"runtime_relative","path":"releases/old","owned":true}},"current_link":{"path_kind":"runtime_relative","path":"current","target":"releases/old","owned":true}}' \
    >"$VIBE_MAC_RUNTIME_ROOT/state/manifest.json"
  printf '%s\n' \
    '{"schema_version":1,"installer_version":"old","last_run_id":"old-run","steps":{"00-preflight":{"status":"pending","completed_at":""}}}' \
    >"$VIBE_MAC_RUNTIME_ROOT/state/progress.json"
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=0
  export VIBE_MAC_TEST_INSTALL_MUTATE_PROGRESS_ONLY=1
  export VIBE_MAC_TEST_INSTALL_FAIL=1

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 7 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = releases/old ]
  [ "$("$VIBE_MAC_PLUTIL_BIN" -extract releases.current.version raw \
    -expect string -- "$VIBE_MAC_RUNTIME_ROOT/state/manifest.json")" = old ]
  [[ "$output" == *"не подтверждают новый active release"* ]]
}

@test "partial invalid active linkage откатывает current" {
  seed_previous_release_state
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=0
  export VIBE_MAC_TEST_INSTALL_MUTATE_INVALID_LINKAGE=1
  export VIBE_MAC_TEST_INSTALL_FAIL=1

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 7 ]
  [ "$(readlink "$VIBE_MAC_RUNTIME_ROOT/current")" = releases/old ]
  [ "$("$VIBE_MAC_PLUTIL_BIN" -extract current_link.target raw \
    -expect string -- "$VIBE_MAC_RUNTIME_ROOT/state/manifest.json")" = \
    releases/old ]
  [[ "$output" == *"не подтверждают новый active release"* ]]
}

@test "initial install target игнорирует BASH_ENV startup payload" {
  startup_sentinel="$TEST_ROOT/initial-target-startup-sentinel"
  startup_payload="$TEST_ROOT/initial-target-bash-env.sh"
  printf '%s\n' \
    'if [ -n "${VIBE_MAC_RELEASE_TREE_SHA256:-}" ]; then' \
    '  /usr/bin/touch "'"$startup_sentinel"'"' \
    'fi' >"$startup_payload"
  export BASH_ENV="$startup_payload"
  export VIBE_MAC_BOOTSTRAP_NO_EXEC=0

  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 0 ]
  assert_path_absent "$startup_sentinel"
}

@test "launcher передаёт аргументы и блокирует current escape" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]
  [ "$(/usr/bin/sed -n '1p' "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify")" = "#!/bin/bash -p" ]
  assert_file_contains \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" \
    '/bin/bash --noprofile --norc -p "$target" "$@"'
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '/usr/bin/printf "%s\n" "$#" >"$HOME/launcher-args.txt"' \
    'for arg in "$@"; do' \
    '  /usr/bin/printf "<%s>\n" "$arg" >>"$HOME/launcher-args.txt"' \
    'done' \
    >"$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION/verify.sh"

  run "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" alpha beta
  [ "$status" -eq 0 ]
  [ "$(/bin/cat "$HOME/launcher-args.txt")" = $'2\n<alpha>\n<beta>' ]

  run /usr/bin/env \
    PATH="$VIBE_MAC_RUNTIME_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    vibe-mac-verify "path lookup"
  [ "$status" -eq 0 ]
  [ "$(/bin/cat "$HOME/launcher-args.txt")" = $'1\n<path lookup>' ]

  /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  ln -s /tmp "$VIBE_MAC_RUNTIME_ROOT/current"
  run "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"
  [ "$status" -eq 2 ]
}

@test "launcher выводит trusted HOME из собственного runtime path" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]

  trusted_home="$HOME"
  launcher="$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"
  trusted_target="$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION/verify.sh"
  trusted_sentinel="$trusted_home/trusted-launcher-target-sentinel"
  attacker_home="$TEST_ROOT/attacker-home"
  attacker_root="$attacker_home/.vibe-mac"
  attacker_sentinel="$TEST_ROOT/attacker-home-target-sentinel"

  printf '%s\n' \
    '#!/bin/bash' \
    '/usr/bin/touch "$HOME/trusted-launcher-target-sentinel"' \
    >"$trusted_target"
  mkdir -p "$attacker_root/releases/evil"
  ln -s releases/evil "$attacker_root/current"
  printf '%s\n' \
    '#!/bin/bash' \
    '/usr/bin/touch "'"$attacker_sentinel"'"' \
    >"$attacker_root/releases/evil/verify.sh"
  /bin/chmod 0700 "$attacker_root/releases/evil/verify.sh"

  run /usr/bin/env HOME="$attacker_home" "$launcher"

  [ "$status" -eq 0 ]
  [ -f "$trusted_sentinel" ]
  assert_path_absent "$attacker_sentinel"
}

@test "launcher и target очищают startup env functions SHELLOPTS и hostile PATH" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]

  launcher="$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"
  target="$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION/verify.sh"
  launcher_startup="$TEST_ROOT/launcher-startup-sentinel"
  target_startup="$TEST_ROOT/target-startup-sentinel"
  env_startup="$TEST_ROOT/env-startup-sentinel"
  launcher_function="$TEST_ROOT/launcher-function-sentinel"
  target_function="$TEST_ROOT/target-function-sentinel"
  hostile_path_sentinel="$TEST_ROOT/hostile-path-sentinel"
  bash_env_payload="$TEST_ROOT/hostile-bash-env.sh"
  env_payload="$TEST_ROOT/hostile-env.sh"
  hostile_path="$TEST_ROOT/hostile-path"
  attacker_runner="$TEST_ROOT/attacker-runner.sh"
  mkdir -p "$hostile_path"

  printf '%s\n' \
    'case "${0##*/}" in' \
    '  vibe-mac-verify) /usr/bin/touch "'"$launcher_startup"'" ;;' \
    '  verify.sh) /usr/bin/touch "'"$target_startup"'" ;;' \
    'esac' >"$bash_env_payload"
  printf '%s\n' \
    '/usr/bin/touch "'"$env_startup"'"' >"$env_payload"

  for command_name in dirname cd pwd printf '[' vibe_target_command; do
    printf '%s\n' \
      '#!/bin/bash' \
      '/usr/bin/touch "'"$hostile_path_sentinel"'"' \
      'exit 93' >"$hostile_path/$command_name"
    /bin/chmod 0700 "$hostile_path/$command_name"
  done

  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'for function_name in dirname cd pwd printf "[" vibe_target_command; do' \
    '  if declare -F "$function_name" >/dev/null 2>&1; then' \
    '    /usr/bin/touch "$HOME/launcher-target-function-leak"' \
    '  fi' \
    'done' \
    'case ":$SHELLOPTS:" in' \
    '  *:xtrace:*) /usr/bin/touch "$HOME/launcher-target-shellopts-leak" ;;' \
    'esac' \
    'dirname /tmp/vibe-mac >/dev/null' \
    'cd "$HOME"' \
    'pwd >/dev/null' \
    'printf "%s" "" >/dev/null' \
    '[ -d "$HOME" ]' \
    'if command -v vibe_target_command >/dev/null 2>&1; then' \
    '  vibe_target_command' \
    'fi' \
    '/usr/bin/printf "%s\\0" "$@" >"$HOME/launcher-args.bin"' \
    '/usr/bin/printf "HOME=%s\nUSER=%s\nLOGNAME=%s\nSHELL=%s\nTERM=%s\nPATH=%s\nTMPDIR=%s\nLC_ALL=%s\nBASH_ENV=%s\nENV=%s\n" \
      "$HOME" "${USER-unset}" "${LOGNAME-unset}" "${SHELL-unset}" \
      "${TERM-unset}" "$PATH" "${TMPDIR-unset}" "${LC_ALL-unset}" \
      "${BASH_ENV-unset}" "${ENV-unset}" >"$HOME/launcher-env.txt"' \
    >"$target"

  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'launcher="$1"' \
    'hostile_path="$2"' \
    'bash_env_payload="$3"' \
    'env_payload="$4"' \
    'launcher_function="$5"' \
    'target_function="$6"' \
    'mark_function_execution() {' \
    '  case "${0##*/}" in' \
    '    vibe-mac-verify) /usr/bin/touch "$launcher_function" ;;' \
    '    verify.sh) /usr/bin/touch "$target_function" ;;' \
    '  esac' \
    '}' \
    'function [ {' \
    '  mark_function_execution' \
    '  builtin [ "$@"' \
    '}' \
    'function dirname {' \
    '  mark_function_execution' \
    '  /usr/bin/dirname "$@"' \
    '}' \
    'function cd {' \
    '  mark_function_execution' \
    '  builtin cd "$@"' \
    '}' \
    'function pwd {' \
    '  mark_function_execution' \
    '  builtin pwd "$@"' \
    '}' \
    'function printf {' \
    '  mark_function_execution' \
    '  builtin printf "$@"' \
    '}' \
    'function vibe_target_command {' \
    '  mark_function_execution' \
    '}' \
    'export launcher_function target_function' \
    'export -f mark_function_execution "[" dirname cd pwd printf vibe_target_command' \
    'exec /usr/bin/env \
      BASH_ENV="$bash_env_payload" ENV="$env_payload" SHELLOPTS=xtrace \
      PATH="$hostile_path" \
      "$launcher" "alpha beta" "" "гамма"' \
    >"$attacker_runner"
  /bin/chmod 0700 "$attacker_runner"

  run /bin/bash "$attacker_runner" \
    "$launcher" "$hostile_path" "$bash_env_payload" "$env_payload" \
    "$launcher_function" "$target_function"

  [ "$status" -eq 0 ]
  assert_path_absent "$launcher_startup"
  assert_path_absent "$target_startup"
  assert_path_absent "$env_startup"
  assert_path_absent "$launcher_function"
  assert_path_absent "$target_function"
  assert_path_absent "$hostile_path_sentinel"
  assert_path_absent "$HOME/launcher-target-function-leak"
  assert_path_absent "$HOME/launcher-target-shellopts-leak"
  run python3 -c '
import pathlib

actual = pathlib.Path("'"$HOME"'/launcher-args.bin").read_bytes()
assert actual == "alpha beta\0\0гамма\0".encode()
'
  [ "$status" -eq 0 ]
  run_user="$(/usr/bin/id -un)"
  [ "$(/bin/cat "$HOME/launcher-env.txt")" = \
    "$(/usr/bin/printf \
      'HOME=%s\nUSER=%s\nLOGNAME=%s\nSHELL=/bin/zsh\nTERM=xterm-256color\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\nTMPDIR=/tmp\nLC_ALL=C\nBASH_ENV=unset\nENV=unset' \
      "$HOME" "$run_user" "$run_user")" ]
}

@test "real macOS Bash 3.2 privileged mode блокирует startup payload" {
  [ "$(uname -s)" = Darwin ] || skip "только системный macOS Bash"
  case "$(/bin/bash --version | /usr/bin/head -n 1)" in
    *'version 3.2.'*) ;;
    *) skip "системный Bash не версии 3.2" ;;
  esac
  startup_sentinel="$TEST_ROOT/bash32-startup-sentinel"
  startup_payload="$TEST_ROOT/bash32-startup-payload.sh"
  printf '%s\n' \
    '/usr/bin/touch "'"$startup_sentinel"'"' >"$startup_payload"

  run /usr/bin/env BASH_ENV="$startup_payload" SHELLOPTS=xtrace \
    /bin/bash --noprofile --norc -p -c 'exit 0'

  [ "$status" -eq 0 ]
  assert_path_absent "$startup_sentinel"
}

@test "launcher блокирует symlink ancestor releases" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]
  outside="$TEST_ROOT/outside-releases"
  /bin/mv "$VIBE_MAC_RUNTIME_ROOT/releases" "$outside"
  ln -s "$outside" "$VIBE_MAC_RUNTIME_ROOT/releases"
  : >"$VIBE_MAC_EVENT_LOG"

  run "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"

  [ "$status" -eq 2 ]
  assert_no_events
}

@test "launcher блокирует symlink собственного bin ancestor" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]
  outside="$TEST_ROOT/outside-bin"
  /bin/mv "$VIBE_MAC_RUNTIME_ROOT/bin" "$outside"
  ln -s "$outside" "$VIBE_MAC_RUNTIME_ROOT/bin"
  : >"$VIBE_MAC_EVENT_LOG"

  run "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"

  [ "$status" -eq 2 ]
  assert_no_events
}

@test "launcher блокирует symlink собственного runtime root" {
  run /bin/bash "$PROJECT_ROOT/bootstrap.sh"
  [ "$status" -eq 0 ]
  original_runtime="$VIBE_MAC_RUNTIME_ROOT"
  outside_parent="$TEST_ROOT/outside-runtime-parent"
  mkdir -p "$outside_parent"
  /bin/mv "$original_runtime" "$outside_parent/.vibe-mac"
  ln -s "$outside_parent/.vibe-mac" "$original_runtime"
  : >"$VIBE_MAC_EVENT_LOG"

  run "$original_runtime/bin/vibe-mac-verify"

  [ "$status" -eq 2 ]
  assert_no_events
}
