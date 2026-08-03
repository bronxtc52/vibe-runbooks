#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
}

@test "json_lint принимает tracked JSON через convert в test и real macOS modes" {
  local tracked before after
  tracked="$PROJECT_ROOT/state/manifest-template.json"
  before="$(shasum -a 256 "$tracked" | awk '{print $1}')"

  run "$VIBE_MAC_PLUTIL_BIN" \
    -convert json -o /dev/null -- "$tracked"
  [ "$status" -eq 0 ]

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_lint "$1"
  ' _ "$tracked"
  [ "$status" -eq 0 ]

  if [ "$(/usr/bin/uname -s)" = Darwin && [ -x /usr/bin/plutil ]; then
    run /usr/bin/env \
      HOME="$HOME" \
      VIBE_MAC_TEST_MODE=0 \
      PROJECT_ROOT="$PROJECT_ROOT" \
      /bin/bash -c '
        source "$PROJECT_ROOT/lib/util.sh"
        json_lint "$1"
      ' _ "$tracked"
    [ "$status" -eq 0 ]
  fi

  after="$(shasum -a 256 "$tracked" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "json_lint отклоняет malformed JSON в test и real macOS modes" {
  local malformed before after
  malformed="$TEST_ROOT/malformed.json"
  printf '%s\n' '{"broken":' >"$malformed"
  before="$(shasum -a 256 "$malformed" | awk '{print $1}')"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_lint "$1"
  ' _ "$malformed"
  [ "$status" -ne 0 ]

  if [ "$(/usr/bin/uname -s)" = Darwin && [ -x /usr/bin/plutil ]; then
    run /usr/bin/env \
      HOME="$HOME" \
      VIBE_MAC_TEST_MODE=0 \
      PROJECT_ROOT="$PROJECT_ROOT" \
      /bin/bash -c '
        source "$PROJECT_ROOT/lib/util.sh"
        json_lint "$1"
      ' _ "$malformed"
    [ "$status" -ne 0 ]
  fi

  after="$(shasum -a 256 "$malformed" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "validate_bool принимает только 0 и 1" {
  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; validate_bool DRY_RUN 1'
  [ "$status" -eq 0 ]

  run /bin/bash -c \
    'source "$PROJECT_ROOT/lib/util.sh"; validate_bool DRY_RUN yes'
  [ "$status" -ne 0 ]
}

@test "generated shell prefix отклоняет apostrophe внутри literal" {
  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    shell_zprofile_managed_content_for_prefix "/tmp/homebrew'\''escape/bin"
  '

  [ "$status" -eq 2 ]
  [ -z "$output" ]
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

@test "production roots нельзя перенаправить переменными окружения" {
  outside="$TEST_ROOT/outside"

  run /usr/bin/env HOME="$HOME" VIBE_MAC_TEST_MODE=0 VIBE_MAC_RUNTIME_ROOT="$outside/runtime" VIBE_MAC_BACKUP_ROOT="$outside/backup" /bin/bash -c '
      source "$PROJECT_ROOT/lib/util.sh"
      printf "%s\n%s\n" "$VIBE_MAC_RUNTIME_ROOT" "$VIBE_MAC_BACKUP_ROOT"
    '

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "$HOME/.vibe-mac" ]
  [ "$(printf '%s\n' "$output" | sed -n '2p')" = "$HOME/.vibe-mac-backup" ]
}

@test "git-archive build marker принудительно выключает test seams" {
  archived_util="$TEST_ROOT/util-release.sh"
  build_commit=0123456789abcdef0123456789abcdef01234567
  /usr/bin/sed \
    "s/\\\$Format:%H\\\$/$build_commit/g" \
    "$PROJECT_ROOT/lib/util.sh" >"$archived_util"
  outside="$TEST_ROOT/outside"

  run /usr/bin/env \
    HOME="$HOME" \
    VIBE_MAC_TEST_MODE=1 \
    VIBE_MAC_RUNTIME_ROOT="$outside" \
    /bin/bash -c '
      source "$1"
      printf "%s\n%s\n%s\n" \
        "$VIBE_MAC_BUILD_KIND" "$VIBE_MAC_TEST_MODE" "$VIBE_MAC_RUNTIME_ROOT"
    ' _ "$archived_util"

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | /usr/bin/sed -n '1p')" = release ]
  [ "$(printf '%s\n' "$output" | /usr/bin/sed -n '2p')" = 0 ]
  [ "$(printf '%s\n' "$output" | /usr/bin/sed -n '3p')" = "$HOME/.vibe-mac" ]
}

@test "runtime root symlink не позволяет выйти из HOME allowlist" {
  outside="$TEST_ROOT/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$HOME/.vibe-mac"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    init_runtime_layout
  '

  [ "$status" -ne 0 ]
  assert_path_absent "$outside/releases"
  assert_path_absent "$outside/state"
}

@test "symlink HOME блокирует создание runtime вне логического HOME" {
  real_home="$TEST_ROOT/real-home"
  linked_home="$TEST_ROOT/linked-home"
  mkdir -p "$real_home"
  ln -s "$real_home" "$linked_home"

  run /usr/bin/env HOME="$linked_home" VIBE_MAC_TEST_MODE=0 /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    init_runtime_layout
  '

  [ "$status" -ne 0 ]
  assert_path_absent "$real_home/.vibe-mac"
}

@test "symlink ancestor пользовательского config блокирует запись" {
  outside="$TEST_ROOT/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$HOME/.config"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    ensure_parent_dir "$HOME/.config/vibe-mac/aliases.zsh"
  '

  [ "$status" -ne 0 ]
  assert_path_absent "$outside/vibe-mac"
}

@test "backup root symlink блокирует создание evidence вне HOME" {
  outside="$TEST_ROOT/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$HOME/.vibe-mac-backup"
  printf '%s\n' user >"$HOME/.zshrc"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    backup_file_once "$HOME/.zshrc" zshrc
  '

  [ "$status" -ne 0 ]
  assert_path_absent "$outside/test-install"
}
