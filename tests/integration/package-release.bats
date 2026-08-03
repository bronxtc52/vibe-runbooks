#!/usr/bin/env bats
# Intentional literal shell snippets and per-test subshell assignments.
# shellcheck disable=SC2016,SC2030,SC2031

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export FIXTURE_REPO="$TEST_ROOT/repo"
  mkdir -p "$FIXTURE_REPO/config" "$FIXTURE_REPO/lib"
  cp "$PROJECT_ROOT/bootstrap.sh" "$FIXTURE_REPO/bootstrap.sh"
  cp "$PROJECT_ROOT/.gitattributes" "$FIXTURE_REPO/.gitattributes"
  cp "$PROJECT_ROOT/lib/util.sh" "$FIXTURE_REPO/lib/util.sh"
  cp "$PROJECT_ROOT/verify.sh" "$FIXTURE_REPO/verify.sh"
  cp "$PROJECT_ROOT/install.sh" "$FIXTURE_REPO/install.sh"
  cp "$PROJECT_ROOT/doctor.sh" "$FIXTURE_REPO/doctor.sh"
  cp "$PROJECT_ROOT/uninstall.sh" "$FIXTURE_REPO/uninstall.sh"
  printf '%s\n' 'VIBE_MAC_VERSION="0.1.0-test"' \
    >"$FIXTURE_REPO/config/versions.env"
  chmod +x "$FIXTURE_REPO/"*.sh
  git -C "$FIXTURE_REPO" init -q -b main
  git -C "$FIXTURE_REPO" config user.name Fixture
  git -C "$FIXTURE_REPO" config user.email fixture@example.invalid
  git -C "$FIXTURE_REPO" add \
    .gitattributes bootstrap.sh install.sh verify.sh doctor.sh uninstall.sh \
    config/versions.env lib/util.sh
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

commit_minimal_bootstrap() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' \
      'release_version="__VIBE_MAC_RELEASE_VERSION__"' \
      'archive_url="__VIBE_MAC_ARCHIVE_URL__"' \
      'archive_sha="__VIBE_MAC_ARCHIVE_SHA256__"' \
      'build_channel="__VIBE_MAC_BOOTSTRAP_BUILD_CHANNEL__"'
    printf '%s\n' \
      '/usr/bin/printf '\''%s|%s|%s\n'\'' "$release_version" "$build_channel" "${VIBE_MAC_SHA256:-}" >"$HOME/bootstrap-executed"'
  } >"$FIXTURE_REPO/bootstrap.sh"
  chmod 0700 "$FIXTURE_REPO/bootstrap.sh"
  git -C "$FIXTURE_REPO" add bootstrap.sh
  GIT_AUTHOR_DATE=2026-08-02T00:00:10Z \
  GIT_COMMITTER_DATE=2026-08-02T00:00:10Z \
    git -C "$FIXTURE_REPO" commit -qm minimal-bootstrap
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
}

make_fake_curl() {
  local source_file log_file fake_curl
  source_file="$1"
  log_file="$2"
  fake_curl="$3"
  {
    printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
    printf 'source_file=%q\n' "$source_file"
    printf 'log_file=%q\n' "$log_file"
    printf '%s\n' \
      'destination=' \
      'while [ "$#" -gt 0 ]; do' \
      '  case "$1" in' \
      '    --output)' \
      '      [ "$#" -ge 2 ] || exit 2' \
      '      destination="$2"' \
      '      shift 2' \
      '      ;;' \
      '    *) shift ;;' \
      '  esac' \
      'done' \
      '[ -n "$destination" ] || exit 2' \
      '/usr/bin/printf '\''called\n'\'' >>"$log_file"' \
      '/bin/cp "$source_file" "$destination"'
  } >"$fake_curl"
  chmod 0700 "$fake_curl"
}

loader_with_fake_curl() {
  local line fake_curl prefix suffix
  line="$(/bin/cat "$1")"
  fake_curl="$2"
  case "$line" in
    *'/usr/bin/curl'*) ;;
    *) return 2 ;;
  esac
  prefix="${line%%/usr/bin/curl*}"
  suffix="${line#*/usr/bin/curl}"
  printf '%s%s%s\n' "$prefix" "$fake_curl" "$suffix"
}

loader_temp_snapshot() {
  /usr/bin/find /tmp -maxdepth 1 -name 'vibe-mac-loader.*' -print |
    LC_ALL=C /usr/bin/sort
}

@test "install-command является одной изолированной shell-командой" {
  run_package "$TEST_ROOT/out"
  [ "$status" -eq 0 ]

  loader="$TEST_ROOT/out/install-command.txt"
  bootstrap_sha="$(awk '{print $1}' \
    "$TEST_ROOT/out/vibe-mac-bootstrap-0.1.0-test.sh.sha256")"
  [ "$(wc -l <"$loader" | tr -d ' ')" -eq 1 ]
  [ "$(grep -cve '^$' "$loader")" -eq 1 ]
  line="$(/bin/cat "$loader")"
  [[ "$line" == *"$bootstrap_sha"* ]]
  [[ "$line" == *'/bin/bash --noprofile --norc -p -c '* ]]
  [[ "$line" != '#!'* ]]
  /bin/bash -n -c "$line"
  if [ -x /bin/zsh ]; then
    /bin/zsh -n -c "$line"
  fi
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
  for placeholder in \
    __VIBE_MAC_RELEASE_VERSION__ \
    __VIBE_MAC_ARCHIVE_URL__ \
    __VIBE_MAC_ARCHIVE_SHA256__ \
    __VIBE_MAC_BOOTSTRAP_BUILD_CHANNEL__; do
    run grep -F "$placeholder" \
      "$TEST_ROOT/out-one/vibe-mac-bootstrap-0.1.0-test.sh"
    [ "$status" -ne 0 ]
  done
  /bin/bash -n "$TEST_ROOT/out-one/vibe-mac-bootstrap-0.1.0-test.sh"
}

@test "release archive содержит только exact commit под одним top-level" {
  run_package "$TEST_ROOT/out"
  [ "$status" -eq 0 ]

  run /usr/bin/tar -tzf "$TEST_ROOT/out/vibe-mac-0.1.0-test.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vibe-mac-0.1.0-test/install.sh"* ]]
  run /usr/bin/grep -Ev '^vibe-mac-0\.1\.0-test/' <<<"$output"
  [ "$status" -eq 1 ]

  mkdir -p "$TEST_ROOT/archive-extracted"
  /usr/bin/tar -xzf "$TEST_ROOT/out/vibe-mac-0.1.0-test.tar.gz" \
    -C "$TEST_ROOT/archive-extracted"
  archived_util="$TEST_ROOT/archive-extracted/vibe-mac-0.1.0-test/lib/util.sh"
  assert_file_contains "$archived_util" "VIBE_MAC_BUILD_COMMIT='$FIXTURE_COMMIT'"
  run /usr/bin/grep -Fq '$Format:%H$' "$archived_util"
  [ "$status" -ne 0 ]
  archived_verify="$TEST_ROOT/archive-extracted/vibe-mac-0.1.0-test/verify.sh"
  assert_file_contains "$archived_verify" \
    "VIBE_MAC_VERIFY_BUILD_COMMIT='$FIXTURE_COMMIT'"
  run /usr/bin/grep -Fq '$Format:%H$' "$archived_verify"
  [ "$status" -ne 0 ]
  archived_install="$TEST_ROOT/archive-extracted/vibe-mac-0.1.0-test/install.sh"
  assert_file_contains "$archived_install" \
    "VIBE_MAC_INSTALL_BUILD_COMMIT='$FIXTURE_COMMIT'"
  run /usr/bin/grep -Fq '$Format:%H$' "$archived_install"
  [ "$status" -ne 0 ]
  archived_doctor="$TEST_ROOT/archive-extracted/vibe-mac-0.1.0-test/doctor.sh"
  assert_file_contains "$archived_doctor" \
    "VIBE_MAC_DOCTOR_BUILD_COMMIT='$FIXTURE_COMMIT'"
  run /usr/bin/grep -Fq '$Format:%H$' "$archived_doctor"
  [ "$status" -ne 0 ]
  archived_uninstall="$TEST_ROOT/archive-extracted/vibe-mac-0.1.0-test/uninstall.sh"
  assert_file_contains "$archived_uninstall" \
    "VIBE_MAC_UNINSTALL_BUILD_COMMIT='$FIXTURE_COMMIT'"
  run /usr/bin/grep -Fq '$Format:%H$' "$archived_uninstall"
  [ "$status" -ne 0 ]
  packaged_bootstrap="$TEST_ROOT/out/vibe-mac-bootstrap-0.1.0-test.sh"
  assert_file_contains "$packaged_bootstrap" \
    'VIBE_MAC_BOOTSTRAP_BUILD_CHANNEL="production"'
  loader="$TEST_ROOT/out/install-command.txt"
  loader_line="$(/bin/cat "$loader")"
  [[ "$loader_line" == \
    *'/usr/bin/env -i HOME="${HOME:-}" PATH=/usr/bin:/bin:/usr/sbin:/sbin'* ]]
  [[ "$loader_line" == *'BASH_ENV=/dev/null ENV=/dev/null'* ]]
  [[ "$loader_line" == *'/usr/bin/curl'* ]]
  [[ "$loader_line" == *'/usr/bin/shasum -a 256 "$temp"'* ]]
  [[ "$loader_line" == *'/bin/bash --noprofile --norc -p "$temp"'* ]]
  [[ "$loader_line" == *'/bin/bash --noprofile --norc -p -c '* ]]
}

@test "one-liner скачивает bootstrap, проверяет SHA и запускает exact fixture" {
  commit_minimal_bootstrap
  run_package "$TEST_ROOT/out"
  [ "$status" -eq 0 ]

  bootstrap="$TEST_ROOT/out/vibe-mac-bootstrap-0.1.0-test.sh"
  bootstrap_sha="$(awk '{print $1}' "$bootstrap.sha256")"
  fake_curl="$TEST_ROOT/fake-curl"
  curl_log="$TEST_ROOT/curl.log"
  make_fake_curl "$bootstrap" "$curl_log" "$fake_curl"
  line="$(loader_with_fake_curl \
    "$TEST_ROOT/out/install-command.txt" "$fake_curl")"
  execution_home="$TEST_ROOT/loader-home"
  mkdir -p "$execution_home"
  execution_home="$(/bin/realpath "$execution_home")"

  run /usr/bin/env HOME="$execution_home" \
    /bin/bash --noprofile --norc -p -c "$line"

  [ "$status" -eq 0 ]
  assert_file_contains "$execution_home/bootstrap-executed" \
    "0.1.0-test|production|$bootstrap_sha"
  [ "$(wc -l <"$curl_log" | tr -d ' ')" -eq 1 ]

  printf '%s\n' '# checksum corruption' >>"$bootstrap"
  /bin/unlink "$execution_home/bootstrap-executed"
  run /usr/bin/env HOME="$execution_home" \
    /bin/bash --noprofile --norc -p -c "$line"

  [ "$status" -eq 2 ]
  [[ "$output" == *"bootstrap SHA не совпал"* ]]
  assert_path_absent "$execution_home/bootstrap-executed"
}

@test "one-liner DRY_RUN не создаёт temp, не вызывает сеть и игнорирует startup hooks" {
  run_package "$TEST_ROOT/out"
  [ "$status" -eq 0 ]
  fake_curl="$TEST_ROOT/fake-curl"
  curl_log="$TEST_ROOT/curl.log"
  make_fake_curl \
    "$TEST_ROOT/out/vibe-mac-bootstrap-0.1.0-test.sh" \
    "$curl_log" "$fake_curl"
  line="$(loader_with_fake_curl \
    "$TEST_ROOT/out/install-command.txt" "$fake_curl")"
  startup_hook="$TEST_ROOT/startup-hook.sh"
  startup_sentinel="$TEST_ROOT/startup-hook-ran"
  printf '/usr/bin/printf ran >%q\n' "$startup_sentinel" >"$startup_hook"
  before="$(loader_temp_snapshot)"

  run /usr/bin/env \
    HOME="$HOME" \
    DRY_RUN=1 \
    BASH_ENV="$startup_hook" \
    ENV="$startup_hook" \
    /bin/bash --noprofile --norc -p -c "$line"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY_RUN"* ]]
  [ "$(loader_temp_snapshot)" = "$before" ]
  assert_path_absent "$curl_log"
  assert_path_absent "$startup_sentinel"
}

@test "one-liner отклоняет malformed flags до temp и сети" {
  run_package "$TEST_ROOT/out"
  [ "$status" -eq 0 ]
  fake_curl="$TEST_ROOT/fake-curl"
  curl_log="$TEST_ROOT/curl.log"
  make_fake_curl \
    "$TEST_ROOT/out/vibe-mac-bootstrap-0.1.0-test.sh" \
    "$curl_log" "$fake_curl"
  line="$(loader_with_fake_curl \
    "$TEST_ROOT/out/install-command.txt" "$fake_curl")"
  before="$(loader_temp_snapshot)"

  for flag in \
    DRY_RUN \
    EXTRAS \
    SKIP_DEFAULTS \
    ALLOW_UNSUPPORTED_INTEL; do
    run /usr/bin/env \
      HOME="$HOME" \
      DRY_RUN=1 \
      EXTRAS=0 \
      SKIP_DEFAULTS=0 \
      ALLOW_UNSUPPORTED_INTEL=0 \
      "$flag=malformed" \
      /bin/bash --noprofile --norc -p -c "$line"

    [ "$status" -eq 2 ]
    [[ "$output" == *"только 0 или 1"* ]]
  done
  [ "$(loader_temp_snapshot)" = "$before" ]
  assert_path_absent "$curl_log"
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

@test "git replace ref не может подменить exact commit release" {
  original="$FIXTURE_COMMIT"
  printf '%s\n' '# malicious replacement' >>"$FIXTURE_REPO/install.sh"
  GIT_AUTHOR_DATE=2026-08-02T00:00:02Z GIT_COMMITTER_DATE=2026-08-02T00:00:02Z git -C "$FIXTURE_REPO" commit -qam replacement
  replacement="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
  git -C "$FIXTURE_REPO" replace "$original" "$replacement"
  FIXTURE_COMMIT="$original"

  run_package "$TEST_ROOT/out"

  [ "$status" -eq 0 ]
  mkdir -p "$TEST_ROOT/extracted"
  /usr/bin/tar -xzf "$TEST_ROOT/out/vibe-mac-0.1.0-test.tar.gz" -C "$TEST_ROOT/extracted"
  run grep -F 'malicious replacement' \
    "$TEST_ROOT/extracted/vibe-mac-0.1.0-test/install.sh"
  [ "$status" -ne 0 ]
}

@test "info attributes в worktree или common git metadata блокируют release" {
  linked_repo="$TEST_ROOT/linked-repo"
  git -C "$FIXTURE_REPO" worktree add -q --detach \
    "$linked_repo" "$FIXTURE_COMMIT"
  FIXTURE_REPO="$linked_repo"
  worktree_git_dir="$(git -C "$FIXTURE_REPO" rev-parse --absolute-git-dir)"
  common_git_dir="$(git -C "$FIXTURE_REPO" rev-parse \
    --path-format=absolute --git-common-dir)"

  index=0
  for metadata_dir in "$worktree_git_dir" "$common_git_dir"; do
    mkdir -p "$metadata_dir/info"
    printf '%s\n' '/lib/util.sh -export-subst' \
      >"$metadata_dir/info/attributes"

    run_package "$TEST_ROOT/out-attributes-$index"

    [ "$status" -eq 2 ]
    assert_path_absent "$TEST_ROOT/out-attributes-$index"
    /bin/unlink "$metadata_dir/info/attributes"
    index=$((index + 1))
  done
}

@test "unsubstituted build marker блокирует release archive" {
  printf '%s\n' \
    '/lib/util.sh -export-subst' \
    '/verify.sh export-subst' >"$FIXTURE_REPO/.gitattributes"
  GIT_AUTHOR_DATE=2026-08-02T00:00:03Z \
  GIT_COMMITTER_DATE=2026-08-02T00:00:03Z \
    git -C "$FIXTURE_REPO" commit -qam missing-export-subst
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

  run_package "$TEST_ROOT/out"

  [ "$status" -eq 2 ]
  [[ "$output" == *"lib/util.sh не содержит exact commit build marker."* ]]
  assert_path_absent "$TEST_ROOT/out"
}

@test "unsubstituted install marker блокирует release archive" {
  /usr/bin/grep -Fvx '/install.sh export-subst' \
    "$FIXTURE_REPO/.gitattributes" \
    >"$FIXTURE_REPO/.gitattributes.next"
  /bin/mv "$FIXTURE_REPO/.gitattributes.next" \
    "$FIXTURE_REPO/.gitattributes"
  git -C "$FIXTURE_REPO" add .gitattributes
  GIT_AUTHOR_DATE=2026-08-02T00:00:04Z \
  GIT_COMMITTER_DATE=2026-08-02T00:00:04Z \
    git -C "$FIXTURE_REPO" commit -qm missing-install-export-subst
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

  run_package "$TEST_ROOT/out"

  [ "$status" -eq 2 ]
  [[ "$output" == \
    *"install.sh не содержит exact commit build marker."* ]]
  assert_path_absent "$TEST_ROOT/out"
}

@test "unsubstituted doctor marker блокирует release archive" {
  /usr/bin/grep -Fvx '/doctor.sh export-subst' \
    "$FIXTURE_REPO/.gitattributes" \
    >"$FIXTURE_REPO/.gitattributes.next"
  /bin/mv "$FIXTURE_REPO/.gitattributes.next" \
    "$FIXTURE_REPO/.gitattributes"
  git -C "$FIXTURE_REPO" add .gitattributes
  GIT_AUTHOR_DATE=2026-08-02T00:00:05Z \
  GIT_COMMITTER_DATE=2026-08-02T00:00:05Z \
    git -C "$FIXTURE_REPO" commit -qm missing-doctor-export-subst
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

  run_package "$TEST_ROOT/out"

  [ "$status" -eq 2 ]
  [[ "$output" == \
    *"doctor.sh не содержит exact commit build marker."* ]]
  assert_path_absent "$TEST_ROOT/out"
}

@test "unsubstituted uninstall marker блокирует release archive" {
  /usr/bin/grep -Fvx '/uninstall.sh export-subst' \
    "$FIXTURE_REPO/.gitattributes" \
    >"$FIXTURE_REPO/.gitattributes.next"
  /bin/mv "$FIXTURE_REPO/.gitattributes.next" \
    "$FIXTURE_REPO/.gitattributes"
  git -C "$FIXTURE_REPO" add .gitattributes
  GIT_AUTHOR_DATE=2026-08-02T00:00:06Z \
  GIT_COMMITTER_DATE=2026-08-02T00:00:06Z \
    git -C "$FIXTURE_REPO" commit -qm missing-uninstall-export-subst
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

  run_package "$TEST_ROOT/out"

  [ "$status" -eq 2 ]
  [[ "$output" == \
    *"uninstall.sh не содержит exact commit build marker."* ]]
  assert_path_absent "$TEST_ROOT/out"
}

@test "shell metacharacters в release URL блокируются до артефактов" {
  bad_urls=(
    'https://example.invalid/$(/usr/bin/id)'
    'https://example.invalid/`/usr/bin/id`'
    'https://example.invalid/"break'
    'https://example.invalid/;touch'
    $'https://example.invalid/archive\n__VIBE_MAC_RELEASE_VERSION__'
    $'https://example.invalid/archive\rproduction'
    $'https://example.invalid/archive\tproduction'
  )
  index=0
  for bad_url in "${bad_urls[@]}"; do
    output_dir="$TEST_ROOT/out-bad-$index"
    run /bin/bash "$PROJECT_ROOT/scripts/package-release.sh" \
      --repo "$FIXTURE_REPO" \
      --commit "$FIXTURE_COMMIT" \
      --version 0.1.0-test \
      --archive-url "$bad_url" \
      --bootstrap-url https://example.invalid/bootstrap.sh \
      --output-dir "$output_dir"

    [ "$status" -eq 2 ]
    assert_path_absent "$output_dir"
    index=$((index + 1))
  done
}
