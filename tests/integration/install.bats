#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_RESPONSE=да
  export VIBE_MAC_STEPS_DIR="$TEST_ROOT/steps"
  export VIBE_MAC_STEP_IDS="00-one 10-two"
  mkdir -p "$VIBE_MAC_STEPS_DIR"
  write_step 00-one
  write_step 10-two
}

write_step() {
  local step_id
  step_id="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'action="${1:-}"'
    printf '%s\n' 'marker="$TEST_ROOT/test-markers/'"$step_id"'"'
    printf '%s\n' 'case "$action" in'
    printf '%s\n' '  plan) printf "plan %s\n" "'"$step_id"'" ;;'
    printf '%s\n' '  detect|verify) [ -f "$marker" ] ;;'
    printf '%s\n' '  apply) mkdir -p "$(dirname "$marker")"; : >"$marker"; printf "apply:%s\n" "'"$step_id"'" >>"$VIBE_MAC_EVENT_LOG"; printf "apply-run %s\n" "'"$step_id"'" ;;'
    printf '%s\n' '  *) exit 2 ;;'
    printf '%s\n' 'esac'
  } >"$VIBE_MAC_STEPS_DIR/$step_id.sh"
  chmod +x "$VIBE_MAC_STEPS_DIR/$step_id.sh"
}

write_integrity_step() {
  local step_id
  step_id="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  plan) printf "integrity plan\n" ;;'
    printf '%s\n' '  detect|verify) exit 2 ;;'
    printf '%s\n' '  apply) printf "integrity-apply\n" >>"$VIBE_MAC_EVENT_LOG" ;;'
    printf '%s\n' '  *) exit 2 ;;'
    printf '%s\n' 'esac'
  } >"$VIBE_MAC_STEPS_DIR/$step_id.sh"
  chmod +x "$VIBE_MAC_STEPS_DIR/$step_id.sh"
}

prepare_fresh_release_fixture() {
  local release launcher tree_sha
  HOME="$(cd "$HOME" && pwd -P)"
  export HOME
  export VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
  export VIBE_MAC_BACKUP_ROOT="$HOME/.vibe-mac-backup"
  export VIBE_MAC_STATE_DIR="$VIBE_MAC_RUNTIME_ROOT/state"
  export VIBE_MAC_LOG_DIR="$VIBE_MAC_RUNTIME_ROOT/logs"
  export VIBE_MAC_STATE_FILE="$VIBE_MAC_STATE_DIR/progress.json"
  export VIBE_MAC_MANIFEST_FILE="$VIBE_MAC_STATE_DIR/manifest.json"
  export VIBE_MAC_LOCK_DIR="$VIBE_MAC_STATE_DIR/install.lock.d"
  export VIBE_MAC_RELEASE_VERSION=0.1.0-test
  release="$VIBE_MAC_RUNTIME_ROOT/releases/$VIBE_MAC_RELEASE_VERSION"
  mkdir -p \
    "$release/config" "$release/lib" "$release/state" \
    "$VIBE_MAC_RUNTIME_ROOT/bin"
  /bin/cp "$PROJECT_ROOT/install.sh" "$release/install.sh"
  /bin/cp "$PROJECT_ROOT/config/versions.env" "$release/config/versions.env"
  /bin/cp "$PROJECT_ROOT/lib/util.sh" "$release/lib/util.sh"
  /bin/cp "$PROJECT_ROOT/lib/ui.sh" "$release/lib/ui.sh"
  /bin/cp "$PROJECT_ROOT/lib/guard.sh" "$release/lib/guard.sh"
  /bin/cp "$PROJECT_ROOT/state/progress-template.json" \
    "$release/state/progress-template.json"
  /bin/cp "$PROJECT_ROOT/state/manifest-template.json" \
    "$release/state/manifest-template.json"
  chmod +x "$release/install.sh"

  for launcher in verify doctor uninstall; do
    printf '%s\n' "trusted $launcher launcher" \
      >"$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher"
    chmod +x "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher"
  done
  ln -s "releases/$VIBE_MAC_RELEASE_VERSION" "$VIBE_MAC_RUNTIME_ROOT/current"

  tree_sha="$(/bin/bash -c '
    source "$1/lib/util.sh"
    release_tree_sha256 "$1"
  ' _ "$release")"
  export VIBE_MAC_RELEASE_ARCHIVE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export VIBE_MAC_RELEASE_TREE_SHA256="$tree_sha"
  printf '%s\n' "$VIBE_MAC_RELEASE_ARCHIVE_SHA256" \
    >"$release/.bundle-sha256"
  printf '%s\n' "$VIBE_MAC_RELEASE_TREE_SHA256" \
    >"$release/.bundle-tree-sha256"

  export VIBE_MAC_LAUNCHER_VERIFY_SHA256
  export VIBE_MAC_LAUNCHER_DOCTOR_SHA256
  export VIBE_MAC_LAUNCHER_UNINSTALL_SHA256
  VIBE_MAC_LAUNCHER_VERIFY_SHA256="$(shasum -a 256 \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" | awk '{print $1}')"
  VIBE_MAC_LAUNCHER_DOCTOR_SHA256="$(shasum -a 256 \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor" | awk '{print $1}')"
  VIBE_MAC_LAUNCHER_UNINSTALL_SHA256="$(shasum -a 256 \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-uninstall" | awk '{print $1}')"
  export VIBE_MAC_TEST_ALLOW_FRESH_RELEASE=1
  FRESH_RELEASE_ROOT="$release"
}

prepare_packaged_install_release() {
  local release tree_sha build_commit
  build_commit=0123456789012345678901234567890123456789
  HOME="$(cd "$HOME" && pwd -P)"
  export HOME
  export VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
  release="$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-packaged"
  mkdir -p "$release/config" "$release/lib"
  /usr/bin/sed \
    "s|'\$Format:%H\$'|'$build_commit'|" \
    "$PROJECT_ROOT/install.sh" >"$release/install.sh"
  /bin/cp "$PROJECT_ROOT/config/versions.env" \
    "$release/config/versions.env"
  /bin/cp "$PROJECT_ROOT/lib/util.sh" "$release/lib/util.sh"
  /bin/cp "$PROJECT_ROOT/lib/ui.sh" "$release/lib/ui.sh"
  /bin/cp "$PROJECT_ROOT/lib/guard.sh" "$release/lib/guard.sh"
  /bin/chmod 0700 "$release/install.sh"
  /bin/chmod 0600 \
    "$release/config/versions.env" \
    "$release/lib/util.sh" \
    "$release/lib/ui.sh" \
    "$release/lib/guard.sh"
  tree_sha="$(/bin/bash -c '
    source "$1/lib/util.sh"
    release_tree_sha256 "$1"
  ' _ "$release")"
  printf '%s\n' \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$release/.bundle-sha256"
  printf '%s\n' "$tree_sha" >"$release/.bundle-tree-sha256"
  /bin/ln -s releases/0.1.0-packaged "$VIBE_MAC_RUNTIME_ROOT/current"
  PACKAGED_INSTALL_ROOT="$release"
}

release_tree_sha256_allow_tab() {
  /bin/bash -c '
    set -euo pipefail
    source "$1/lib/util.sh"
    (
      cd "$2"
      /usr/bin/find . -mindepth 1 -print0 |
        while IFS= read -r -d "" path; do
          case "$path" in
            ./.bundle-sha256|./.bundle-tree-sha256) continue ;;
          esac
          printf "%s\n" "$path"
        done |
        LC_ALL=C /usr/bin/sort |
        while IFS= read -r path; do
          if [ -f "$path" ] && [ ! -L "$path" ]; then
            printf "F\t%s\t%s\t%s\n" \
              "$(file_mode "$path")" "$(sha256_file "$path")" "$path"
          elif [ -d "$path" ] && [ ! -L "$path" ]; then
            printf "D\t%s\t-\t%s\n" "$(file_mode "$path")" "$path"
          else
            exit 2
          fi
        done
    ) | sha256_stdin
  ' _ "$PROJECT_ROOT" "$1"
}

@test "install выполняет шаги по порядку, а второй запуск не мутирует" {
  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$VIBE_MAC_EVENT_LOG")" = "apply:00-one" ]
  [ "$(sed -n '2p' "$VIBE_MAC_EVENT_LOG")" = "apply:10-two" ]

  first_hash="$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')"
  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  second_hash="$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')"
  [ "$first_hash" = "$second_hash" ]
}

@test "missing manifest при completed progress блокирует install до шагов" {
  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]

  progress_sha="$(shasum -a 256 "$VIBE_MAC_STATE_FILE" | awk '{print $1}')"
  event_sha="$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')"
  /bin/unlink "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 2 ]
  assert_path_absent "$VIBE_MAC_MANIFEST_FILE"
  [ "$progress_sha" = "$(shasum -a 256 "$VIBE_MAC_STATE_FILE" | awk '{print $1}')" ]
  [ "$event_sha" = "$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')" ]
}

@test "corrupt manifest при completed progress остаётся byte-for-byte" {
  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]

  printf '%s\n' '{corrupt' >"$VIBE_MAC_MANIFEST_FILE"
  manifest_sha="$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')"
  event_sha="$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 2 ]
  [ "$manifest_sha" = "$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')" ]
  [ "$event_sha" = "$(shasum -a 256 "$VIBE_MAC_EVENT_LOG" | awk '{print $1}')" ]
}

@test "точно свежий progress без manifest разрешает первый install" {
  mkdir -p "$VIBE_MAC_STATE_DIR"
  /bin/cp "$PROJECT_ROOT/state/progress-template.json" "$VIBE_MAC_STATE_FILE"

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 0 ]
  [ -f "$VIBE_MAC_MANIFEST_FILE" ]
  [ "$(grep -c '^apply:' "$VIBE_MAC_EVENT_LOG")" -eq 2 ]
}

@test "orphan ownership evidence без manifest блокирует первый install" {
  mkdir -p "$VIBE_MAC_STATE_DIR" "$VIBE_MAC_BACKUP_ROOT/orphan-install"
  /bin/cp "$PROJECT_ROOT/state/progress-template.json" "$VIBE_MAC_STATE_FILE"
  printf '%s\n' absent >"$VIBE_MAC_BACKUP_ROOT/orphan-install/zprofile.absent"

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 2 ]
  assert_path_absent "$VIBE_MAC_MANIFEST_FILE"
  assert_no_events
}

@test "exact fresh bootstrap release разрешает создать первый manifest" {
  prepare_fresh_release_fixture

  run /bin/bash "$FRESH_RELEASE_ROOT/install.sh"

  [ "$status" -eq 0 ]
  [ -f "$VIBE_MAC_MANIFEST_FILE" ]
  [ "$("$VIBE_MAC_PLUTIL_BIN" -extract releases.current.version raw -- \
    "$VIBE_MAC_MANIFEST_FILE")" = "$VIBE_MAC_RELEASE_VERSION" ]
}

@test "packaged install проверяет release tree до source tampered util" {
  prepare_packaged_install_release
  printf '%s\n' ': >"$HOME/presource-install-sentinel"' \
    >>"$PACKAGED_INSTALL_ROOT/lib/util.sh"

  run /bin/bash "$PACKAGED_INSTALL_ROOT/install.sh"

  [ "$status" -eq 2 ]
  assert_path_absent "$HOME/presource-install-sentinel"
}

@test "packaged install включает nested bundle marker в fingerprint" {
  prepare_packaged_install_release
  printf '%s\n' ': >"$HOME/presource-install-nested-sentinel"' \
    >>"$PACKAGED_INSTALL_ROOT/lib/util.sh"
  tree_sha="$(/bin/bash -c '
    source "$1/lib/util.sh"
    release_tree_sha256 "$2"
  ' _ "$PROJECT_ROOT" "$PACKAGED_INSTALL_ROOT")"
  printf '%s\n' "$tree_sha" \
    >"$PACKAGED_INSTALL_ROOT/.bundle-tree-sha256"
  mkdir -p "$PACKAGED_INSTALL_ROOT/nested"
  printf '%s\n' nested-tamper \
    >"$PACKAGED_INSTALL_ROOT/nested/.bundle-sha256"

  run /bin/bash "$PACKAGED_INSTALL_ROOT/install.sh"

  [ "$status" -eq 2 ]
  assert_path_absent "$HOME/presource-install-nested-sentinel"
}

@test "packaged install отклоняет TAB path до source" {
  prepare_packaged_install_release
  printf '%s\n' ': >"$HOME/presource-install-tab-sentinel"' \
    >>"$PACKAGED_INSTALL_ROOT/lib/util.sh"
  printf '%s\n' tab-path >"$PACKAGED_INSTALL_ROOT/"$'tab\tpath'
  tree_sha="$(release_tree_sha256_allow_tab "$PACKAGED_INSTALL_ROOT")"
  printf '%s\n' "$tree_sha" \
    >"$PACKAGED_INSTALL_ROOT/.bundle-tree-sha256"

  run /bin/bash "$PACKAGED_INSTALL_ROOT/install.sh"

  [ "$status" -eq 2 ]
  assert_path_absent "$HOME/presource-install-tab-sentinel"
}

@test "packaged DRY_RUN pre-source integrity остаётся zero-write" {
  local -a sandbox_argv
  prepare_packaged_install_release
  printf '%s\n' 'exit 17' >>"$PACKAGED_INSTALL_ROOT/lib/util.sh"
  tree_sha="$(/bin/bash -c '
    source "$1/lib/util.sh"
    release_tree_sha256 "$2"
  ' _ "$PROJECT_ROOT" "$PACKAGED_INSTALL_ROOT")"
  printf '%s\n' "$tree_sha" \
    >"$PACKAGED_INSTALL_ROOT/.bundle-tree-sha256"
  mkdir -p "$TEST_ROOT/unwritable-tmp"
  chmod 0500 "$TEST_ROOT/unwritable-tmp"
  before="$(/usr/bin/find "$TEST_ROOT/unwritable-tmp" -print |
    LC_ALL=C /usr/bin/sort | shasum -a 256 | awk '{print $1}')"
  sandbox_argv=()
  if [ -x /usr/bin/sandbox-exec ]; then
    sandbox_argv=(
      /usr/bin/sandbox-exec
      -p
      '(version 1) (allow default) (deny file-write*) (allow file-write* (literal "/dev/null"))'
    )
  fi

  run /usr/bin/env \
    DRY_RUN=1 \
    TMPDIR="$TEST_ROOT/unwritable-tmp" \
    "${sandbox_argv[@]}" \
    /bin/bash "$PACKAGED_INSTALL_ROOT/install.sh"
  after="$(/usr/bin/find "$TEST_ROOT/unwritable-tmp" -print |
    LC_ALL=C /usr/bin/sort | shasum -a 256 | awk '{print $1}')"
  chmod 0700 "$TEST_ROOT/unwritable-tmp"

  [ "$status" -eq 17 ]
  [ "$before" = "$after" ]
  run /usr/bin/grep -F 'vibe-mac.install-integrity.' \
    "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 1 ]
}

@test "pending onboarding применяется один раз даже при зелёном verify" {
  export VIBE_MAC_STEP_IDS="60-ai-agents"
  write_step 60-ai-agents
  mkdir -p "$TEST_ROOT/test-markers"
  : >"$TEST_ROOT/test-markers/60-ai-agents"

  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apply:60-ai-agents$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]

  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apply:60-ai-agents$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
}

@test "pending shell и runtimes всегда проходят reconcile даже при зелёном verify" {
  export VIBE_MAC_STEP_IDS="40-shell 50-runtimes"
  write_step 40-shell
  write_step 50-runtimes
  mkdir -p "$TEST_ROOT/test-markers"
  : >"$TEST_ROOT/test-markers/40-shell"
  : >"$TEST_ROOT/test-markers/50-runtimes"

  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apply:40-shell$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^apply:50-runtimes$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]

  run /bin/bash "$PROJECT_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apply:40-shell$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
  [ "$(grep -c '^apply:50-runtimes$' "$VIBE_MAC_EVENT_LOG")" -eq 1 ]
}

@test "integrity exit verify останавливает install до apply и сохраняет exit 2" {
  export VIBE_MAC_STEP_IDS="00-integrity"
  write_integrity_step 00-integrity

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 2 ]
  assert_no_events
}

@test "integrity exit verify сохраняется в DRY_RUN" {
  export VIBE_MAC_STEP_IDS="00-integrity"
  export DRY_RUN=1
  write_integrity_step 00-integrity

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 2 ]
  assert_no_events
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT"
}

@test "Intel apply показывает полный dry plan до typed gate и не мутирует при отказе" {
  export VIBE_MAC_TEST_ARCH=x86_64
  export ALLOW_UNSUPPORTED_INTEL=1
  export VIBE_MAC_TEST_RESPONSE=wrong

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"plan 00-one"* ]]
  [[ "$output" == *"plan 10-two"* ]]
  assert_no_events
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT"
}

@test "Intel apply после полного dry plan требует точное INTEL" {
  export VIBE_MAC_TEST_ARCH=x86_64
  export ALLOW_UNSUPPORTED_INTEL=1
  export VIBE_MAC_TEST_RESPONSE=INTEL

  run /bin/bash "$PROJECT_ROOT/install.sh"

  [ "$status" -eq 0 ]
  case "$output" in
    *"plan 00-one"*"plan 10-two"*"apply-run 00-one"*) ;;
    *) false ;;
  esac
  [ "$(grep -c '^apply:' "$VIBE_MAC_EVENT_LOG")" -eq 2 ]
}

@test "CLT не вызывает GUI без human gate" {
  export VIBE_MAC_TEST_CLT_MARKER="$TEST_ROOT/clt-installed"
  export VIBE_MAC_TEST_PAUSE=deny
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/10-xcode-clt.sh" apply

  [ "$status" -ne 0 ]
  assert_path_absent "$VIBE_MAC_TEST_CLT_MARKER"
  assert_no_events
}

@test "CLT вызывает системный шаг только после Enter" {
  export VIBE_MAC_TEST_CLT_MARKER="$TEST_ROOT/clt-installed"
  export VIBE_MAC_TEST_PAUSE=ok
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/10-xcode-clt.sh" apply

  [ "$status" -eq 0 ]
  [ -f "$VIBE_MAC_TEST_CLT_MARKER" ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "xcode-select --install"
}

@test "Homebrew не начинает privileged phase без да" {
  export VIBE_MAC_TEST_HOMEBREW_MARKER="$TEST_ROOT/homebrew-installed"
  export VIBE_MAC_TEST_RESPONSE=нет
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" apply

  [ "$status" -ne 0 ]
  assert_path_absent "$VIBE_MAC_TEST_HOMEBREW_MARKER"
  assert_no_events
}

@test "Homebrew после да проходит test privileged trace" {
  export VIBE_MAC_TEST_HOMEBREW_MARKER="$TEST_ROOT/homebrew-installed"
  export VIBE_MAC_TEST_RESPONSE=да
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" apply

  [ "$status" -eq 0 ]
  [ -f "$VIBE_MAC_TEST_HOMEBREW_MARKER" ]
  [ "$(sed -n '1p' "$VIBE_MAC_EVENT_LOG")" = "homebrew:confirmed" ]
  [ "$(sed -n '2p' "$VIBE_MAC_EVENT_LOG")" = "homebrew-install" ]
}
