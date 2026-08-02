#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export FIXTURE_REPO="$TEST_ROOT/repo"
  mkdir -p "$FIXTURE_REPO/config"
  cp "$PROJECT_ROOT/bootstrap.sh" "$FIXTURE_REPO/bootstrap.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'exit 0' >"$FIXTURE_REPO/install.sh"
  for entry in verify doctor uninstall; do
    cp "$FIXTURE_REPO/install.sh" "$FIXTURE_REPO/$entry.sh"
  done
  printf '%s\n' 'VIBE_MAC_VERSION="0.1.0-test"' \
    >"$FIXTURE_REPO/config/versions.env"
  chmod +x "$FIXTURE_REPO/"*.sh
  git -C "$FIXTURE_REPO" init -q -b main
  git -C "$FIXTURE_REPO" config user.name Fixture
  git -C "$FIXTURE_REPO" config user.email fixture@example.invalid
  git -C "$FIXTURE_REPO" add \
    bootstrap.sh install.sh verify.sh doctor.sh uninstall.sh config/versions.env
  GIT_AUTHOR_DATE=2026-08-02T00:00:00Z \
  GIT_COMMITTER_DATE=2026-08-02T00:00:00Z \
    git -C "$FIXTURE_REPO" commit -qm fixture
  export FIXTURE_COMMIT
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
}

run_package() {
  local output_dir
  output_dir="$1"
  run /bin/bash "$PROJECT_ROOT/scripts/package-release.sh" \
    --repo "$FIXTURE_REPO" \
    --commit "$FIXTURE_COMMIT" \
    --version 0.1.0-test \
    --archive-url https://example.invalid/vibe-mac-0.1.0-test.tar.gz \
    --bootstrap-url https://example.invalid/vibe-mac-bootstrap-0.1.0-test.sh \
    --output-dir "$output_dir"
}

@test "два package build одного commit дают одинаковые SHA" {
  run_package "$TEST_ROOT/out-one"
  [ "$status" -eq 0 ]
  run_package "$TEST_ROOT/out-two"
  [ "$status" -eq 0 ]

  for artifact in \
    vibe-mac-0.1.0-test.tar.gz \
    vibe-mac-bootstrap-0.1.0-test.sh \
    install-command.txt; do
    first_sha="$(shasum -a 256 "$TEST_ROOT/out-one/$artifact" | awk '{print $1}')"
    second_sha="$(shasum -a 256 "$TEST_ROOT/out-two/$artifact" | awk '{print $1}')"
    [ "$first_sha" = "$second_sha" ]
  done
  ! grep -F '__VIBE_MAC_' \
    "$TEST_ROOT/out-one/vibe-mac-bootstrap-0.1.0-test.sh"
  /bin/bash -n "$TEST_ROOT/out-one/vibe-mac-bootstrap-0.1.0-test.sh"
}

@test "release archive содержит только exact commit под одним top-level" {
  run_package "$TEST_ROOT/out"
  [ "$status" -eq 0 ]

  run /usr/bin/tar -tzf "$TEST_ROOT/out/vibe-mac-0.1.0-test.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vibe-mac-0.1.0-test/install.sh"* ]]
  ! printf '%s\n' "$output" | grep -Ev '^vibe-mac-0\.1\.0-test/' | grep -q .
}

@test "tracked symlink блокирует package до артефактов" {
  ln -s /tmp "$FIXTURE_REPO/escape"
  git -C "$FIXTURE_REPO" add escape
  GIT_AUTHOR_DATE=2026-08-02T00:00:01Z \
  GIT_COMMITTER_DATE=2026-08-02T00:00:01Z \
    git -C "$FIXTURE_REPO" commit -qm symlink
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

  run_package "$TEST_ROOT/out"

  [ "$status" -eq 2 ]
  assert_path_absent "$TEST_ROOT/out"
}
