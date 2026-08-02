#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
}

@test "validate_bool принимает только 0 и 1" {
  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; validate_bool DRY_RUN 1'
  [ "$status" -eq 0 ]

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; validate_bool DRY_RUN yes'
  [ "$status" -ne 0 ]
}

@test "retry делает не больше трёх попыток" {
  counter="$TEST_ROOT/counter"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    flaky() {
      count=0
      if [ -f "$1" ]; then count="$(cat "$1")"; fi
      count=$((count + 1))
      printf "%s\n" "$count" >"$1"
      [ "$count" -ge 3 ]
    }
    retry flaky "$2"
  ' _ unused "$counter"

  [ "$status" -eq 0 ]
  [ "$(cat "$counter")" -eq 3 ]
}

@test "home-relative path не принимает parent traversal" {
  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; validate_home_relative ".zshrc"'
  [ "$status" -eq 0 ]

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; validate_home_relative "../escape"'
  [ "$status" -ne 0 ]
}

@test "safe_download принимает только файл с ожидаемым SHA-256" {
  make_fake_command curl-stub '
    target=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output" ]; then
        shift
        target="$1"
      fi
      shift
    done
    printf payload >"$target"
  '
  export VIBE_MAC_CURL_BIN="$TEST_ROOT/fake-bin/curl-stub"
  target="$TEST_ROOT/download"
  expected="$(printf payload | shasum -a 256 | awk '{print $1}')"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    safe_download "https://example.test/file" "$1" "$2"
  ' _ "$target" "$expected"

  [ "$status" -eq 0 ]
  [ "$(cat "$target")" = payload ]
}

@test "safe_download удаляет файл при несовпадении SHA-256" {
  make_fake_command curl-stub '
    target=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output" ]; then
        shift
        target="$1"
      fi
      shift
    done
    printf changed >"$target"
  '
  export VIBE_MAC_CURL_BIN="$TEST_ROOT/fake-bin/curl-stub"
  target="$TEST_ROOT/download"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    safe_download "https://example.test/file" "$1" "0000000000000000000000000000000000000000000000000000000000000000"
  ' _ "$target"

  [ "$status" -ne 0 ]
  assert_path_absent "$target"
}

@test "version_at_least сравнивает date-style версии mise" {
  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; version_at_least 2026.8.0 2026.8.0'
  [ "$status" -eq 0 ]

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; version_at_least 2026.7.9 2026.8.0'
  [ "$status" -ne 0 ]
}
