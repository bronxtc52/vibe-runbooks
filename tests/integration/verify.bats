#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  setup_verify_bundle
  export VIBE_MAC_TEST_VERIFY_RESULTS="1 1 1 1 1 1 1 1 1 1 1 1"
}

setup_verify_bundle() {
  local tree_sha
  VERIFY_RELEASE="$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test"
  VERIFY_SCRIPT="$VERIFY_RELEASE/verify.sh"
  export VERIFY_RELEASE VERIFY_SCRIPT

  mkdir -p "$VERIFY_RELEASE"
  cp "$PROJECT_ROOT/install.sh" "$VERIFY_RELEASE/install.sh"
  cp "$PROJECT_ROOT/verify.sh" "$VERIFY_RELEASE/verify.sh"
  cp -R "$PROJECT_ROOT/config" "$VERIFY_RELEASE/config"
  cp -R "$PROJECT_ROOT/lib" "$VERIFY_RELEASE/lib"
  cp -R "$PROJECT_ROOT/steps" "$VERIFY_RELEASE/steps"
  ln -s releases/0.1.0-test "$VIBE_MAC_RUNTIME_ROOT/current"

  # shellcheck source=lib/util.sh
  source "$PROJECT_ROOT/lib/util.sh"
  tree_sha="$(release_tree_sha256 "$VERIFY_RELEASE")"
  printf '%s\n' \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$VERIFY_RELEASE/.bundle-sha256"
  printf '%s\n' "$tree_sha" >"$VERIFY_RELEASE/.bundle-tree-sha256"

  mkdir -p "$VIBE_MAC_STATE_DIR"
  cp "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace install_id -string test-install -- "$VIBE_MAC_MANIFEST_FILE"
  "$VIBE_MAC_PLUTIL_BIN" \
    -insert files.starship -json '{"owned":false}' -- \
    "$VIBE_MAC_MANIFEST_FILE"
  record_verify_release_graph
}

record_verify_release_graph() {
  local archive_sha id launcher launcher_sha tree_sha version
  version="${VERIFY_RELEASE##*/}"
  archive_sha="$(/bin/cat "$VERIFY_RELEASE/.bundle-sha256")"
  tree_sha="$(/bin/cat "$VERIFY_RELEASE/.bundle-tree-sha256")"
  mkdir -p "$VIBE_MAC_RUNTIME_ROOT/bin"
  for id in verify doctor uninstall; do
    launcher="$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$id"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$launcher"
    chmod 0700 "$launcher"
    launcher_sha="$(sha256_file "$launcher")"
    json_set_json_atomic \
      "$VIBE_MAC_MANIFEST_FILE" "launchers.$id" \
      "{\"path_kind\":\"runtime_relative\",\"path\":\"bin/vibe-mac-$id\",\"sha256\":\"$launcher_sha\",\"owned\":true}"
  done
  json_set_json_atomic \
    "$VIBE_MAC_MANIFEST_FILE" releases.current \
    "{\"version\":\"$version\",\"path_kind\":\"runtime_relative\",\"path\":\"releases/$version\",\"archive_sha256\":\"$archive_sha\",\"tree_sha256\":\"$tree_sha\",\"owned\":true}"
  json_set_json_atomic \
    "$VIBE_MAC_MANIFEST_FILE" current_link \
    "{\"path_kind\":\"runtime_relative\",\"path\":\"current\",\"target\":\"releases/$version\",\"owned\":true}"
}

assert_integrity_failure() {
  [ "$status" -eq 2 ]
  [[ "$output" == *"README"* ]]
  [[ "$output" == *"versioned bootstrap"* ]]
  [[ "$output" != *"Исправить:"* ]]
  [[ "$output" != *"$HOME/.vibe-mac/current/install.sh"* ]]
}

assert_manifest_integrity_failure() {
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest.json"* ]]
  [[ "$output" != *"из 12 готово"* ]]
}

assert_verify_rejected_before_probes() {
  [ "$status" -eq 2 ]
  [[ "$output" != *"из 12 готово"* ]]
  assert_no_events
}

@test "verify печатает 12 из 12 и остаётся read-only" {
  before="$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^\[')" -eq 12 ]
  after="$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  assert_no_events
}

@test "один красный probe даёт exit 1 и ровно одну repair-команду" {
  export VIBE_MAC_TEST_VERIFY_RESULTS="1 1 1 1 1 1 1 0 1 1 1 1"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"11 из 12 готово"* ]]
  [[ "$output" == *"[Ошибка] Node.js"* ]]
  [ "$(printf '%s\n' "$output" |
    grep -Fc 'versioned bootstrap-команду для нужной версии')" -eq 1 ]
  [[ "$output" != *"$HOME/.vibe-mac/current/install.sh"* ]]
}

@test "невалидный test result делает verify fail-closed с exit 2" {
  export VIBE_MAC_TEST_VERIFY_RESULTS="1 1 broken"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"Некорректные test probes"* ]]
}

@test "verify fail-closed до probes когда current отсутствует" {
  unlink "$VIBE_MAC_RUNTIME_ROOT/current"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_integrity_failure
  [[ "$output" != *"из 12 готово"* ]]
}

@test "verify fail-closed если HOME является symlink" {
  local real_home
  real_home="$TEST_ROOT/real-home"
  /bin/mv "$HOME" "$real_home"
  /bin/ln -s "$real_home" "$HOME"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_integrity_failure
  [[ "$output" == *"HOME"* ]]
  [[ "$output" != *"из 12 готово"* ]]
}

@test "verify нельзя запускать из checkout вместо активного release" {
  run /bin/bash "$PROJECT_ROOT/verify.sh"

  assert_integrity_failure
  [[ "$output" == *"не из активного release"* ]]
}

@test "production verify игнорирует runtime root override" {
  export VIBE_MAC_TEST_MODE=0
  export VIBE_MAC_RUNTIME_ROOT="$TEST_ROOT/outside-runtime"

  run /bin/bash "$VERIFY_SCRIPT" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Запуск: /bin/bash ./verify.sh"* ]]
  [[ "$output" != *"bundle vibe-mac отсутствует или повреждён"* ]]
}

@test "verify fail-closed когда current не symlink или выходит из releases" {
  unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  mkdir "$VIBE_MAC_RUNTIME_ROOT/current"

  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure

  rmdir "$VIBE_MAC_RUNTIME_ROOT/current"
  ln -s ../../outside "$VIBE_MAC_RUNTIME_ROOT/current"
  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure
}

@test "verify fail-closed для unsafe release version" {
  unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  ln -s 'releases/bad..version' "$VIBE_MAC_RUNTIME_ROOT/current"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_integrity_failure
}

@test "verify требует regular install.sh" {
  unlink "$VERIFY_RELEASE/install.sh"

  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure

  ln -s /bin/true "$VERIFY_RELEASE/install.sh"
  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure
}

@test "verify требует оба regular SHA marker" {
  unlink "$VERIFY_RELEASE/.bundle-sha256"

  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure

  printf '%s\n' \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$VERIFY_RELEASE/.bundle-sha256"
  unlink "$VERIFY_RELEASE/.bundle-tree-sha256"
  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure
}

@test "verify отклоняет malformed archive marker и изменённый release tree" {
  printf '%s\n' not-a-sha >"$VERIFY_RELEASE/.bundle-sha256"

  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure

  printf '%s\n' \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$VERIFY_RELEASE/.bundle-sha256"
  printf '%s\n' '# tampered' >>"$VERIFY_RELEASE/config/versions.env"
  run /bin/bash "$VERIFY_SCRIPT"
  assert_integrity_failure
}

@test "nested bundle marker name обязательно меняет release tree hash" {
  mkdir -p "$VERIFY_RELEASE/nested"
  printf '%s\n' nested-marker \
    >"$VERIFY_RELEASE/nested/.bundle-tree-sha256"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_integrity_failure
  [[ "$output" == *"release tree fingerprint"* ]]
}

@test "verify pre-source tree walker отклоняет TAB в имени пути" {
  local tab_path
  tab_path="$VERIFY_RELEASE/path"$'\t'"with-tab"
  printf '%s\n' tabbed >"$tab_path"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_integrity_failure
  [[ "$output" == *"release tree нельзя безопасно проверить"* ]]
}

@test "verify даёт integrity 2 без установленного manifest" {
  /bin/unlink "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_manifest_integrity_failure
}

@test "verify даёт integrity 2 для corrupt manifest" {
  printf '%s\n' '{broken' >"$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_manifest_integrity_failure
}

@test "verify даёт integrity 2 без Starship ownership field" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace files.starship -json '{}' -- "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_manifest_integrity_failure
}

@test "verify даёт integrity 2 без Oh My Zsh ownership field" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace components.oh_my_zsh -json '{"tree_sha256":""}' -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_manifest_integrity_failure
}

@test "verify отклоняет строку вместо typed ownership bool" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace files.starship.owned -string false -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_manifest_integrity_failure
}

@test "verify отклоняет owned Oh My Zsh без валидного tree hash" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace components.oh_my_zsh.owned -bool true -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_manifest_integrity_failure
}

@test "verify допускает typed owned=false для Starship и Oh My Zsh" {
  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
}

make_verify_command() {
  local name body clean_guard
  name="$1"
  body="$2"
  clean_guard='
    if [ "${VIBE_MAC_TEST_VERIFY_CLEAN_PROBE:-0}" = 1 ]; then
      fixture_home="${VIBE_MAC_TEST_VERIFY_FIXTURE_HOME:-}"
      [ -n "$fixture_home" ] || exit 97
      expected_path="$(/bin/cat "$fixture_home/.vibe-mac-test-clean-path")"
      expected_cwd="$(/bin/cat "$fixture_home/.vibe-mac-test-clean-cwd")"
      [ "${USER:-}" = "$(/usr/bin/id -un)" ] || exit 97
      [ "${LOGNAME:-}" = "$(/usr/bin/id -un)" ] || exit 97
      [ "${SHELL:-}" = /bin/zsh ] || exit 97
      [ "${PATH:-}" = "$expected_path" ] || exit 97
      [ "${LANG:-}" = C ] || exit 97
      [ "${LC_ALL:-}" = C ] || exit 97
      [ "$(/bin/pwd -P)" = "$expected_cwd" ] || exit 97
      [ "${DO_NOT_TRACK:-}" = 1 ] || exit 97
      [ "${GH_TELEMETRY:-}" = disabled ] || exit 97
      [ "${HOMEBREW_NO_ANALYTICS:-}" = 1 ] || exit 97
      [ "${HOMEBREW_NO_AUTO_UPDATE:-}" = 1 ] || exit 97
      [ "${HOMEBREW_NO_INSTALL_UPGRADE:-}" = 1 ] || exit 97
      [ "${HOMEBREW_NO_INSTALL_CLEANUP:-}" = 1 ] || exit 97
      [ "${HOMEBREW_NO_ENV_HINTS:-}" = 1 ] || exit 97
      [ "${DISABLE_AUTOUPDATER:-}" = 1 ] || exit 97
      [ "${DISABLE_TELEMETRY:-}" = 1 ] || exit 97
      [ "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" = 1 ] || exit 97
      for variable in \
        NODE_OPTIONS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR \
        GH_HOST GH_CONFIG_DIR MISE_CONFIG_FILE MISE_NODE_MIRROR_URL \
        MISE_PYTHON_COMPILE MISE_BACKENDS XDG_CONFIG_HOME XDG_DATA_HOME \
        XDG_CACHE_HOME XDG_STATE_HOME PYTHONPATH PYTHONHOME UV_CONFIG_FILE; do
        [ -z "${!variable:-}" ] || exit 97
      done
      if [ "${0##*/}" = mise ]; then
        [ "$HOME" = "$fixture_home" ] || exit 97
        [ "${TMPDIR:-}" = /tmp ] || exit 97
        expected_config="$(/bin/cat "$fixture_home/.vibe-mac-test-trusted-config-dir")"
        [ "${1:-}" = -C ] || exit 97
        [ "${2:-}" = "$expected_config" ] || exit 97
        [ "${MISE_YES:-}" = 1 ] || exit 97
        [ "${MISE_AUTO_INSTALL:-}" = 0 ] || exit 97
        [ "${MISE_EXEC_AUTO_INSTALL:-}" = 0 ] || exit 97
        [ "${MISE_OFFLINE:-}" = 1 ] || exit 97
        [ "${MISE_CONFIG_DIR:-}" = "$expected_config" ] || exit 97
        [ "${MISE_GLOBAL_CONFIG_FILE:-}" = /dev/null ] || exit 97
        [ "${MISE_SYSTEM_CONFIG_FILE:-}" = /dev/null ] || exit 97
        [ "${MISE_DATA_DIR:-}" = "$HOME/.local/share/mise" ] || exit 97
        [ "${MISE_CACHE_DIR:-}" = "$HOME/.cache/mise" ] || exit 97
        [ "${MISE_STATE_DIR:-}" = "$HOME/.local/state/mise" ] || exit 97
        [ "${MISE_TMP_DIR:-}" = /tmp ] || exit 97
      else
        [ "$HOME" = /var/empty ] || exit 97
        [ "${TMPDIR:-}" = /var/empty ] || exit 97
        for variable in \
          MISE_YES MISE_AUTO_INSTALL MISE_EXEC_AUTO_INSTALL MISE_OFFLINE \
          MISE_CONFIG_DIR MISE_GLOBAL_CONFIG_FILE \
          MISE_SYSTEM_CONFIG_FILE MISE_DATA_DIR MISE_CACHE_DIR \
          MISE_STATE_DIR MISE_TMP_DIR; do
          [ -z "${!variable:-}" ] || exit 97
        done
      fi
      printf "clean-probe:%s:%s\n" "${0##*/}" "$*" \
        >>"$fixture_home/.vibe-mac-clean-probes.log"
    fi
  '
  make_fake_command "$name" "$clean_guard
$body"
  if [ -n "${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" ] &&
    [ -d "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin" ]; then
    /bin/cp "$TEST_ROOT/fake-bin/$name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$name"
  fi
}

make_verify_app_bundle() {
  local app executable identifier
  app="$1"
  executable="$2"
  identifier="$3"
  mkdir -p "$app/Contents/MacOS"
  printf '%s\n' \
    '{' \
    "  \"CFBundleExecutable\": \"$executable\"," \
    "  \"CFBundleIdentifier\": \"$identifier\"" \
    '}' >"$app/Contents/Info.plist"
  printf '%s\n' '#!/bin/sh' 'exit 0' \
    >"$app/Contents/MacOS/$executable"
  chmod 0755 "$app/Contents/MacOS/$executable"
}

setup_real_verify_fixture() {
  local command_name font_file node_bin python_bin
  unset VIBE_MAC_TEST_VERIFY_RESULTS
  export VIBE_MAC_TEST_CLT=installed
  export VIBE_MAC_TEST_HOMEBREW=installed
  export VIBE_MAC_TEST_AI_READY=1
  export VIBE_MAC_TEST_GHOSTTY_APP="$TEST_ROOT/Ghostty.app"
  export VIBE_MAC_TEST_CURSOR_APP="$TEST_ROOT/Cursor.app"
  export VIBE_MAC_TEST_APPLICATIONS_ROOT="$TEST_ROOT"
  export VIBE_MAC_TEST_FONT_DIR="$HOME/Library/Fonts"
  export VIBE_MAC_TEST_ZSH_BIN="$TEST_ROOT/system-zsh"
  mkdir -p \
    "$VIBE_MAC_TEST_FONT_DIR" \
    "$HOME/.config/vibe-mac" \
    "$HOME/Library/Application Support/com.mitchellh.ghostty" \
    "$HOME/dev/hello-vibe"
  make_verify_app_bundle \
    "$VIBE_MAC_TEST_GHOSTTY_APP" Ghostty com.mitchellh.ghostty
  make_verify_app_bundle \
    "$VIBE_MAC_TEST_CURSOR_APP" Cursor com.todesktop.230313mzl4w4u92
  font_file="$VIBE_MAC_TEST_FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf"
  /bin/dd if=/dev/zero of="$font_file" bs=1024 count=1 2>/dev/null
  printf '\000\001\000\000' | /bin/dd \
    of="$font_file" bs=1 count=4 conv=notrunc 2>/dev/null
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$VIBE_MAC_TEST_ZSH_BIN"
  chmod +x "$VIBE_MAC_TEST_ZSH_BIN"
  cp "$PROJECT_ROOT/config/AGENTS.md" "$HOME/dev/hello-vibe/AGENTS.md"
  cp "$PROJECT_ROOT/config/CLAUDE.md" "$HOME/dev/hello-vibe/CLAUDE.md"
  cp "$PROJECT_ROOT/config/mise.toml" "$HOME/dev/hello-vibe/.mise.toml"
  cp "$PROJECT_ROOT/config/FIRST-PROMPT.md" \
    "$HOME/dev/hello-vibe/FIRST-PROMPT.md"
  : >"$HOME/dev/hello-vibe/index.html"
  /usr/bin/git -C "$HOME/dev/hello-vibe" init -q -b feat/first-page
  node_bin="$HOME/.local/share/mise/installs/node/24.18.1/bin/node"
  python_bin="$HOME/.local/share/mise/installs/python/3.12.13/bin/python"
  mkdir -p "${node_bin%/*}" "${python_bin%/*}"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$node_bin"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$python_bin"
  chmod 0755 "$node_bin" "$python_bin"

  make_verify_command git 'exec /usr/bin/git "$@"'
  make_verify_command brew '
    case "${1:-}" in
      --prefix) printf "%s\n" "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" ;;
      --version) printf "%s\n" "Homebrew 5.0" ;;
      list)
        case "${2:-}" in
          --formula|--cask)
            [ -n "${3:-}" ] || exit 2
            fixture_home="${VIBE_MAC_TEST_VERIFY_FIXTURE_HOME:-$HOME}"
            missing="$fixture_home/.vibe-mac-test-missing-brew-receipt"
            [ ! -f "$missing" ] ||
              [ "$(/bin/cat "$missing")" != "${3:-}" ]
            ;;
          *) exit 2 ;;
        esac
        ;;
      *) exit 2 ;;
    esac
  '
  make_verify_command gh '
    case "${1:-}" in
      --version) printf "%s\n" "gh version 2.80.0" ;;
      *) exit 0 ;;
    esac
  '
  for command_name in claude codex cursor-agent; do
    make_verify_command "$command_name" \
      'printf "%s\n" "${0##*/} 1.0"'
  done
  for command_name in rg fd fzf bat eza jq tree zoxide; do
    make_verify_command "$command_name" \
      'printf "%s\n" "${0##*/} 1.0"'
  done
  make_verify_command mise '
    case "${1:-}" in
      -C)
        case "${3:-}" in
          --version) printf "%s\n" "mise 2026.8.0" ;;
          where)
            case "${4:-}" in
              node@24.18.1)
                printf "%s\n" \
                  "$HOME/.local/share/mise/installs/node/24.18.1"
                ;;
              python@3.12.13)
                printf "%s\n" \
                  "$HOME/.local/share/mise/installs/python/3.12.13"
                ;;
              *) exit 2 ;;
            esac
            ;;
          exec)
            case "${6:-}" in
              node) printf "%s\n" "v24.18.1" ;;
              python) printf "%s\n" "Python 3.12.13" ;;
              *) exit 2 ;;
            esac
            ;;
          *) exit 2 ;;
        esac
        ;;
      *) exit 2 ;;
    esac
  '
  make_verify_command uv 'printf "%s\n" "uv 0.12.1"'
  make_verify_command starship 'printf "%s\n" "starship 1.0"'
  VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX
  mkdir -p \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/sbin"
  for command_name in \
    brew git gh claude codex cursor-agent \
    rg fd fzf bat eza jq tree zoxide mise uv starship; do
    /bin/cp \
      "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  /bin/unlink "$VIBE_MAC_MANIFEST_FILE"
  /bin/bash -c '
    source "$VERIFY_RELEASE/config/versions.env"
    source "$VERIFY_RELEASE/lib/util.sh"
    mkdir -p "$VIBE_MAC_STATE_DIR"
    manifest_init \
      "$PROJECT_ROOT/state/manifest-template.json" \
      "$VIBE_MAC_MANIFEST_FILE"
  '
  record_verify_release_graph
  /bin/bash "$VERIFY_RELEASE/steps/40-shell.sh" apply
  : >"$VIBE_MAC_EVENT_LOG"
}

@test "real probe wiring даёт 12/12 на полном synthetic fixture" {
  setup_real_verify_fixture

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
}

@test "verify typed manifest отклоняет string schema до probes" {
  setup_real_verify_fixture
  "$VIBE_MAC_PLUTIL_BIN" -replace schema_version -string 1 -- \
    "$VIBE_MAC_MANIFEST_FILE"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_verify_rejected_before_probes
  [[ "$output" == *"manifest.json"* ]]
}

@test "verify typed manifest отклоняет forged release owned string до probes" {
  setup_real_verify_fixture
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace releases.current.owned -string true -- \
    "$VIBE_MAC_MANIFEST_FILE"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_verify_rejected_before_probes
  [[ "$output" == *"manifest.json"* ]]
}

@test "verify typed manifest отклоняет forged launcher owned string до probes" {
  setup_real_verify_fixture
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace launchers.verify.owned -string true -- \
    "$VIBE_MAC_MANIFEST_FILE"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_verify_rejected_before_probes
  [[ "$output" == *"manifest.json"* ]]
}

@test "verify связывает archive marker с manifest до probes" {
  setup_real_verify_fixture
  printf '%s\n' \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    >"$VERIFY_RELEASE/.bundle-sha256"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_verify_rejected_before_probes
  [[ "$output" == *"manifest.json"* ]]
}

@test "verify связывает tree marker и actual tree с manifest до probes" {
  setup_real_verify_fixture
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace releases.current.tree_sha256 -string \
    cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc -- \
    "$VIBE_MAC_MANIFEST_FILE"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_verify_rejected_before_probes
  [[ "$output" == *"manifest.json"* ]]
}

@test "verify отклоняет current symlink drift до probes" {
  setup_real_verify_fixture
  /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  /bin/ln -s releases/another "$VIBE_MAC_RUNTIME_ROOT/current"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_verify_rejected_before_probes
}

@test "verify отклоняет launcher hash drift до probes" {
  setup_real_verify_fixture
  printf '%s\n' tampered \
    >>"$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  assert_verify_rejected_before_probes
  [[ "$output" == *"manifest.json"* ]]
}

@test "real verify печатает фактические версии успешных групп" {
  setup_real_verify_fixture

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Homebrew 5.0"* ]]
  [[ "$output" == *"git version"* ]]
  [[ "$output" == *"mise 2026.8.0"* ]]
  [[ "$output" == *"v24.18.1"* ]]
  [[ "$output" == *"Python 3.12.13"* ]]
  [[ "$output" == *"uv 0.12.1"* ]]
  [[ "$output" == *"rg 1.0"* ]]
  [[ "$output" == *"claude 1.0"* ]]
}

@test "Homebrew aggregate красный без одного Brewfile receipt" {
  setup_real_verify_fixture
  printf '%s\n' mise >"$HOME/.vibe-mac-test-missing-brew-receipt"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] Homebrew"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^\[Ошибка\]')" -eq 1 ]
}

@test "version details не печатают raw control characters" {
  setup_real_verify_fixture
  make_verify_command claude \
    'printf "\033[31mclaude 1.0\033[0m\n"'

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude 1.0"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "shell probe отвергает bare PATH init внутри managed block" {
  setup_real_verify_fixture
  unsafe="$TEST_ROOT/zshrc-with-bare-init"
  /usr/bin/awk '
    $0 == "# <<< vibe-mac managed:zshrc <<<" {
      print "eval \"$(starship init zsh)\""
    }
    { print }
  ' "$HOME/.zshrc" >"$unsafe"
  /bin/mv "$unsafe" "$HOME/.zshrc"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "Homebrew probe красный если brew --version завершается с ошибкой" {
  setup_real_verify_fixture
  make_verify_command brew '
    case "${1:-}" in
      --prefix) printf "%s\n" "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" ;;
      --version) exit 9 ;;
      list) exit 0 ;;
      *) exit 2 ;;
    esac
  '

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] Homebrew"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^\[Ошибка\]')" -eq 1 ]
}

@test "GitHub CLI probe красный если gh --version завершается с ошибкой" {
  setup_real_verify_fixture
  make_verify_command gh 'exit 1'

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] Git и GitHub CLI"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^\[Ошибка\]')" -eq 1 ]
}

@test "full verify игнорирует исполняемые подмены раньше trusted Homebrew prefix" {
  local command_name malicious_bin
  setup_real_verify_fixture
  malicious_bin="$TEST_ROOT/malicious-bin"
  mkdir -p "$malicious_bin"
  for command_name in \
    brew git gh claude codex cursor-agent \
    rg fd fzf bat eza jq tree zoxide mise uv starship; do
    {
      printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
      printf '%s\n' \
        'printf "malicious:%s\n" "$0" >>"$VIBE_MAC_EVENT_LOG"'
      printf '%s\n' 'exit 9'
    } >"$malicious_bin/$command_name"
    chmod +x "$malicious_bin/$command_name"
  done
  PATH="$malicious_bin:$PATH"
  export PATH

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
  assert_no_events
}

@test "full verify сохраняет integrity 2 для external Homebrew symlink" {
  local external
  setup_real_verify_fixture
  external="$TEST_ROOT/external-starship"
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" executed:external-starship >>"$HOME/.external-executed"' \
    'exit 0' >"$external"
  chmod 0755 "$external"
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/starship"
  /bin/ln -s "$external" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/starship"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"zsh, Oh My Zsh, Starship и шрифт: проверка не смогла выполниться"* ]]
  [ ! -e "$HOME/.external-executed" ]
  [ ! -L "$HOME/.external-executed" ]
}

@test "all version and runtime probes ignore hostile environment overrides" {
  local command_name
  setup_real_verify_fixture
  printf '%s\n' \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    >"$HOME/.vibe-mac-test-clean-path"
  printf '%s\n' "$(cd "$VERIFY_RELEASE/config" && pwd -P)" \
    >"$HOME/.vibe-mac-test-trusted-config-dir"
  printf '%s\n' "$(cd /var/empty && pwd -P)" \
    >"$HOME/.vibe-mac-test-clean-cwd"
  : >"$HOME/.vibe-mac-clean-probes.log"
  mkdir -p "$TEST_ROOT/hostile-tmp"
  export VIBE_MAC_TEST_VERIFY_CLEAN_PROBE=1
  export USER=hostile-user LOGNAME=hostile-logname SHELL=/bin/false
  export PATH="$TEST_ROOT/hostile-bin:$PATH"
  export TMPDIR="$TEST_ROOT/hostile-tmp"
  export NODE_OPTIONS=--trace-warnings
  export GIT_CONFIG_GLOBAL="$TEST_ROOT/hostile-git-global"
  export GIT_CONFIG_SYSTEM="$TEST_ROOT/hostile-git-system"
  export GIT_DIR="$TEST_ROOT/hostile-git-dir"
  export GH_HOST=enterprise.invalid
  export GH_CONFIG_DIR="$TEST_ROOT/hostile-gh-config"
  export MISE_CONFIG_DIR="$TEST_ROOT/hostile-mise-config"
  export MISE_CONFIG_FILE="$TEST_ROOT/hostile-mise-file"
  export MISE_GLOBAL_CONFIG_FILE="$TEST_ROOT/hostile-mise-global"
  export MISE_SYSTEM_CONFIG_FILE="$TEST_ROOT/hostile-mise-system"
  export MISE_DATA_DIR="$TEST_ROOT/hostile-mise-data"
  export MISE_CACHE_DIR="$TEST_ROOT/hostile-mise-cache"
  export MISE_STATE_DIR="$TEST_ROOT/hostile-mise-state"
  export MISE_TMP_DIR="$TEST_ROOT/hostile-mise-tmp"
  export MISE_NODE_MIRROR_URL=https://attacker.invalid/node
  export MISE_PYTHON_COMPILE=1
  export MISE_BACKENDS="$TEST_ROOT/hostile-mise-backends"
  export MISE_AUTO_INSTALL=1
  export MISE_EXEC_AUTO_INSTALL=1
  export MISE_OFFLINE=0
  export XDG_CONFIG_HOME="$TEST_ROOT/hostile-xdg-config"
  export XDG_DATA_HOME="$TEST_ROOT/hostile-xdg-data"
  export XDG_CACHE_HOME="$TEST_ROOT/hostile-xdg-cache"
  export XDG_STATE_HOME="$TEST_ROOT/hostile-xdg-state"
  export PYTHONPATH="$TEST_ROOT/hostile-python-path"
  export UV_CONFIG_FILE="$TEST_ROOT/hostile-uv-config"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
  for command_name in \
    brew git gh starship rg fd fzf bat eza jq tree zoxide mise uv \
    claude codex cursor-agent; do
    grep -q "^clean-probe:$command_name:" \
      "$HOME/.vibe-mac-clean-probes.log"
  done
  grep -q '^clean-probe:mise:.* node --version$' \
    "$HOME/.vibe-mac-clean-probes.log"
  grep -q '^clean-probe:mise:.* python --version$' \
    "$HOME/.vibe-mac-clean-probes.log"
}

@test "verify missing mise runtime остаётся offline и не auto-install" {
  local node_root
  setup_real_verify_fixture
  node_root="$HOME/.local/share/mise/installs/node/24.18.1"
  /usr/bin/find "$node_root" -depth -delete
  make_verify_command mise '
    if [ "${MISE_AUTO_INSTALL:-}" != 0 ] ||
      [ "${MISE_EXEC_AUTO_INSTALL:-}" != 0 ] ||
      [ "${MISE_OFFLINE:-}" != 1 ]; then
      printf "%s\n" mise-network-or-write >>"$VIBE_MAC_EVENT_LOG"
      /bin/mkdir -p "$HOME/.local/share/mise/installs/node/24.18.1"
    fi
    case "${1:-}" in
      -C)
        case "${3:-}" in
          --version) printf "%s\n" "mise 2026.8.0" ;;
          where)
            case "${4:-}" in
              node@24.18.1) exit 1 ;;
              python@3.12.13)
                printf "%s\n" \
                  "$HOME/.local/share/mise/installs/python/3.12.13"
                ;;
              *) exit 2 ;;
            esac
            ;;
          exec)
            case "${6:-}" in
              node)
                printf "%s\n" mise-exec-missing-node >>"$VIBE_MAC_EVENT_LOG"
                exit 2
                ;;
              python) printf "%s\n" "Python 3.12.13" ;;
              *) exit 2 ;;
            esac
            ;;
          *) exit 2 ;;
        esac
        ;;
      *) exit 2 ;;
    esac
  '
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] Node.js"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
  [ ! -e "$node_root" ]
  [ ! -L "$node_root" ]
  assert_no_events
}

@test "verify блокирует mise where вне exact versioned runtime path" {
  local external_node
  setup_real_verify_fixture
  external_node="$HOME/external-node"
  mkdir -p "$external_node/bin"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$external_node/bin/node"
  chmod 0755 "$external_node/bin/node"
  make_verify_command mise '
    case "${1:-}" in
      -C)
        case "${3:-}" in
          --version) printf "%s\n" "mise 2026.8.0" ;;
          where)
            case "${4:-}" in
              node@24.18.1) printf "%s\n" "$HOME/external-node" ;;
              python@3.12.13)
                printf "%s\n" \
                  "$HOME/.local/share/mise/installs/python/3.12.13"
                ;;
              *) exit 2 ;;
            esac
            ;;
          exec)
            case "${6:-}" in
              node)
                printf "%s\n" executed-node >"$HOME/.mise-exec-outside"
                printf "%s\n" "v24.18.1"
                ;;
              python) printf "%s\n" "Python 3.12.13" ;;
              *) exit 2 ;;
            esac
            ;;
          *) exit 2 ;;
        esac
        ;;
      *) exit 2 ;;
    esac
  '

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"Node.js: проверка не смогла выполниться"* ]]
  [ ! -e "$HOME/.mise-exec-outside" ]
  [ ! -L "$HOME/.mise-exec-outside" ]
}

@test "default verify не вызывает auth и tripwire подтверждает offline no-write env" {
  local name
  setup_real_verify_fixture
  make_verify_command brew '
    if [ "$HOME" != /var/empty ] || [ "${TMPDIR:-}" != /var/empty ] ||
      [ "${DO_NOT_TRACK:-}" != 1 ] ||
      [ "${HOMEBREW_NO_AUTO_UPDATE:-}" != 1 ] ||
      [ "${HOMEBREW_NO_ANALYTICS:-}" != 1 ]; then
      printf "%s\n" "tripwire:brew-network-or-write" \
        >>"$VIBE_MAC_EVENT_LOG"
      exit 97
    fi
    case "${1:-}" in
      --version) printf "%s\n" "Homebrew 5.0" ;;
      list) exit 0 ;;
      *) exit 2 ;;
    esac
  '
  for name in gh claude codex cursor-agent; do
    make_verify_command "$name" '
      if [ "$HOME" != /var/empty ] || [ "${TMPDIR:-}" != /var/empty ] ||
        [ "${DO_NOT_TRACK:-}" != 1 ] ||
        [ "${GH_TELEMETRY:-}" != disabled ] ||
        [ "${DISABLE_AUTOUPDATER:-}" != 1 ] ||
        [ "${DISABLE_TELEMETRY:-}" != 1 ] ||
        [ "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" != 1 ]; then
        printf "tripwire:%s-network-or-write\n" "${0##*/}" \
          >>"$VIBE_MAC_EVENT_LOG"
        exit 97
      fi
      if [ "$*" = --version ]; then
        printf "%s\n" "${0##*/} 1.0"
        exit
      fi
      printf "auth-executed:%s:%s\n" "${0##*/}" "$*" \
        >>"$VIBE_MAC_EVENT_LOG"
      exit 98
    '
  done
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
  [[ "$output" == *"Вход GitHub: не проверяется офлайн"* ]]
  [[ "$output" == *"Вход Claude: не проверяется офлайн"* ]]
  [[ "$output" == *"Вход Codex: не проверяется офлайн"* ]]
  [[ "$output" == *"Вход Cursor Agent: не проверяется офлайн"* ]]
  assert_no_events
}

@test "verify печатает exact trusted manual status и login commands" {
  local prefix
  setup_real_verify_fixture
  prefix="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^  Проверить:')" -eq 4 ]
  [ "$(printf '%s\n' "$output" | grep -c '^  Войти:')" -eq 4 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Проверить: $prefix/bin/gh auth status --hostname github.com")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Войти: $prefix/bin/gh auth login --hostname github.com --web --git-protocol https")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Проверить: $prefix/bin/claude auth status --text")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Войти: $prefix/bin/claude auth login")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Проверить: $prefix/bin/codex login status")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Войти: $prefix/bin/codex login")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Проверить: $prefix/bin/cursor-agent status")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    "  Войти: $prefix/bin/cursor-agent login")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc \
    '  Проверить и войти: /usr/bin/open /Applications/Cursor.app')" -eq 1 ]
  [ "$(printf '%s\n' "$output" |
    grep -Ec '^  (Проверить|Войти): (gh|claude|codex|cursor-agent)( |$)' ||
    true)" -eq 0 ]
}

@test "verify исполняет только version из Cellar и не запускает auth" {
  local cellar command_name expected_cellar prefix
  setup_real_verify_fixture
  prefix="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX"
  for command_name in gh claude codex cursor-agent; do
    make_verify_command "$command_name" '
      if [ "$*" = --version ]; then
        printf "version-path:%s|%s\n" "${0##*/}" "$0" \
          >>"$VIBE_MAC_EVENT_LOG"
        printf "%s\n" "${0##*/} 1.0"
        exit
      fi
      printf "auth-executed:%s:%s\n" "${0##*/}" "$*" \
        >>"$VIBE_MAC_EVENT_LOG"
      exit 98
    '
  done
  cellar="$prefix/Cellar/test-tools/1/bin"
  mkdir -p "$cellar"
  for command_name in gh claude codex cursor-agent; do
    /bin/mv "$prefix/bin/$command_name" "$cellar/$command_name"
    /bin/ln -s "../Cellar/test-tools/1/bin/$command_name" \
      "$prefix/bin/$command_name"
  done
  expected_cellar="$(cd "$cellar" && pwd -P)"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
  for command_name in gh claude codex cursor-agent; do
    grep -Fqx \
      "version-path:$command_name|$expected_cellar/$command_name" \
      "$VIBE_MAC_EVENT_LOG"
    grep -Fq "  Проверить: $prefix/bin/$command_name" <<<"$output"
  done
  [ "$(grep -c '^version-path:' "$VIBE_MAC_EVENT_LOG")" -eq 4 ]
  [ "$(grep -c '^auth-executed:' "$VIBE_MAC_EVENT_LOG" || true)" -eq 0 ]
}

@test "verify auth fail-closed для external config symlinks без execute" {
  local config_path external name
  setup_real_verify_fixture
  make_verify_command gh '
    case "${1:-}" in
      --version) printf "%s\n" "gh version 2.80.0" ;;
      auth) printf "%s\n" "auth-executed:gh" >>"$VIBE_MAC_EVENT_LOG" ;;
      *) exit 2 ;;
    esac
  '
  for name in claude codex cursor-agent; do
    make_verify_command "$name" '
      [ "${1:-}" != --version ] || {
        printf "%s\n" "${0##*/} 1.0"
        exit
      }
      printf "auth-executed:%s\n" "${0##*/}" >>"$VIBE_MAC_EVENT_LOG"
    '
  done
  external="$TEST_ROOT/external-auth-config"
  mkdir -p "$external/gh" "$external/claude" \
    "$external/codex" "$external/cursor"
  for config_path in \
    "$HOME/.config/gh:$external/gh" \
    "$HOME/.claude:$external/claude" \
    "$HOME/.codex:$external/codex" \
    "$HOME/.cursor:$external/cursor"; do
    /bin/ln -s "${config_path#*:}" "${config_path%%:*}"
  done
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"Вход GitHub: integrity-ошибка конфигурации"* ]]
  [[ "$output" == *"Вход Claude: integrity-ошибка конфигурации"* ]]
  [[ "$output" == *"Вход Codex: integrity-ошибка конфигурации"* ]]
  [[ "$output" == *"Вход Cursor Agent: integrity-ошибка конфигурации"* ]]
  [ "$(grep -c '^auth-executed:' "$VIBE_MAC_EVENT_LOG" || true)" -eq 0 ]
}

@test "install DRY_RUN не исполняет brew git и gh при filesystem detect" {
  setup_real_verify_fixture
  make_verify_command brew \
    'printf "%s\n" "called:brew" >>"$VIBE_MAC_EVENT_LOG"; exit 9'
  make_verify_command git \
    'printf "%s\n" "called:git" >>"$VIBE_MAC_EVENT_LOG"; exit 9'
  make_verify_command gh \
    'printf "%s\n" "called:gh" >>"$VIBE_MAC_EVENT_LOG"; exit 9'

  run /usr/bin/env DRY_RUN=1 VIBE_MAC_FULL_VERIFY=0 \
    /bin/bash "$VERIFY_RELEASE/steps/20-homebrew.sh" verify
  [ "$status" -eq 0 ]
  run /usr/bin/env DRY_RUN=1 VIBE_MAC_FULL_VERIFY=0 \
    /bin/bash "$VERIFY_RELEASE/steps/70-git-github.sh" verify
  [ "$status" -eq 0 ]
  assert_no_events
}

@test "AI probe красный если любая version-команда завершается с ошибкой" {
  local command_name
  setup_real_verify_fixture

  for command_name in claude codex cursor-agent; do
    make_verify_command "$command_name" 'exit 1'

    run /bin/bash "$VERIFY_SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"[Ошибка] AI CLI и Cursor"* ]]
    [[ "$output" == *"11 из 12 готово"* ]]
    make_verify_command "$command_name" 'printf "%s\n" "tool 1.0"'
  done
}

@test "CLI probe красный если любая version-команда завершается с ошибкой" {
  local command_name
  setup_real_verify_fixture

  for command_name in rg fd fzf bat eza jq tree zoxide; do
    make_verify_command "$command_name" 'exit 9'

    run /bin/bash "$VERIFY_SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"[Ошибка] CLI-набор"* ]]
    [[ "$output" == *"11 из 12 готово"* ]]
    make_verify_command "$command_name" 'printf "%s\n" "tool 1.0"'
  done
}

@test "shell probe красный если starship --version завершается с ошибкой" {
  setup_real_verify_fixture
  make_verify_command starship 'exit 9'

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
}

@test "один missing CLI красит только агрегат CLI-набор" {
  setup_real_verify_fixture
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/fd"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] CLI-набор"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^\[Ошибка\]')" -eq 1 ]
}

@test "shell probe красный без executable zsh" {
  setup_real_verify_fixture
  unlink "$VIBE_MAC_TEST_ZSH_BIN"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный без regular oh-my-zsh.sh" {
  setup_real_verify_fixture
  unlink "$HOME/.oh-my-zsh/oh-my-zsh.sh"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный без executable starship" {
  setup_real_verify_fixture
  chmod -x "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/starship"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"zsh, Oh My Zsh, Starship и шрифт: проверка не смогла выполниться"* ]]
}

@test "shell probe красный без current zprofile managed block" {
  setup_real_verify_fixture
  printf '%s\n' 'user-only' >"$HOME/.zprofile"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный без current zshrc managed block" {
  setup_real_verify_fixture
  printf '%s\n' 'user-only' >"$HOME/.zshrc"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный для activation-only без внешнего Oh My Zsh source" {
  setup_real_verify_fixture
  printf '%s\n' 'source "$ZSH/oh-my-zsh.sh"' >>"$HOME/.zshrc"
  /bin/bash "$VERIFY_RELEASE/steps/40-shell.sh" apply
  sed -i.bak '/^source "$ZSH\/oh-my-zsh.sh"$/d' "$HOME/.zshrc"
  /bin/unlink "$HOME/.zshrc.bak"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный без current ghostty managed block" {
  setup_real_verify_fixture
  printf '%s\n' 'user-only' \
    >"$HOME/Library/Application Support/com.mitchellh.ghostty/config"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный при tamper exact Ghostty block" {
  setup_real_verify_fixture
  ghostty="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  sed -i.bak 's/font-size = 14/font-size = 99/' "$ghostty"
  /bin/unlink "$ghostty.bak"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный при tamper owned aliases" {
  setup_real_verify_fixture
  printf '%s\n' 'echo aliases-tampered' >>"$HOME/.config/vibe-mac/aliases.zsh"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный при tamper owned Starship template" {
  setup_real_verify_fixture
  printf '%s\n' '# starship-tampered' >>"$HOME/.config/starship.toml"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный при tamper owned Oh My Zsh tree" {
  setup_real_verify_fixture
  printf '%s\n' 'echo omz-tampered' >>"$HOME/.oh-my-zsh/oh-my-zsh.sh"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный без Nerd Font" {
  setup_real_verify_fixture
  unlink "$VIBE_MAC_TEST_FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "shell probe красный для zero-byte Nerd Font" {
  setup_real_verify_fixture
  : >"$VIBE_MAC_TEST_FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
}

@test "Ghostty probe красный для пустого app bundle" {
  setup_real_verify_fixture
  /bin/mv "$VIBE_MAC_TEST_GHOSTTY_APP" "$TEST_ROOT/valid-Ghostty.app"
  mkdir "$VIBE_MAC_TEST_GHOSTTY_APP"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] Ghostty"* ]]
}

@test "AI probe красный для пустого Cursor app bundle" {
  setup_real_verify_fixture
  /bin/mv "$VIBE_MAC_TEST_CURSOR_APP" "$TEST_ROOT/valid-Cursor.app"
  mkdir "$VIBE_MAC_TEST_CURSOR_APP"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] AI CLI и Cursor"* ]]
}

@test "AI probe отклоняет composite CFBundleExecutable" {
  local composite_executable info
  setup_real_verify_fixture
  info="$VIBE_MAC_TEST_CURSOR_APP/Contents/Info.plist"
  composite_executable='{"name":"Cursor"}'
  printf '%s\n' \
    '{' \
    '  "CFBundleExecutable": {"name":"Cursor"},' \
    '  "CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"' \
    '}' >"$info"
  printf '%s\n' '#!/bin/sh' 'exit 0' \
    >"$VIBE_MAC_TEST_CURSOR_APP/Contents/MacOS/$composite_executable"
  chmod 0755 \
    "$VIBE_MAC_TEST_CURSOR_APP/Contents/MacOS/$composite_executable"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] AI CLI и Cursor"* ]]
}

@test "Ghostty probe красный если app path является symlink" {
  local real_app
  setup_real_verify_fixture
  real_app="$TEST_ROOT/real-Ghostty.app"
  /bin/mv "$VIBE_MAC_TEST_GHOSTTY_APP" "$real_app"
  /bin/ln -s "$real_app" "$VIBE_MAC_TEST_GHOSTTY_APP"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] Ghostty"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
}

@test "shell probe красный если font directory является symlink" {
  local real_font_dir
  setup_real_verify_fixture
  real_font_dir="$TEST_ROOT/real-fonts"
  /bin/mv "$VIBE_MAC_TEST_FONT_DIR" "$real_font_dir"
  /bin/ln -s "$real_font_dir" "$VIBE_MAC_TEST_FONT_DIR"

  run /bin/bash "$VERIFY_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] zsh, Oh My Zsh, Starship и шрифт"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
}
