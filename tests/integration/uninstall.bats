#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers

  mkdir -p \
    "$HOME/.config/vibe-mac" \
    "$HOME/dev/hello-vibe" \
    "$VIBE_MAC_BACKUP_ROOT/test-install" \
    "$VIBE_MAC_LOG_DIR"
  printf '%s\n' \
    "user line" \
    "# >>> vibe-mac managed:zprofile >>>" \
    "managed line" \
    "# <<< vibe-mac managed:zprofile <<<" >"$HOME/.zprofile"
  printf '%s\n' "owned aliases" >"$HOME/.config/vibe-mac/aliases.zsh"
  printf '%s\n' "keep workspace" >"$HOME/dev/hello-vibe/sentinel"
  printf '%s\n' "keep backup" >"$VIBE_MAC_BACKUP_ROOT/test-install/sentinel"
  printf '%s\n' "keep log" >"$VIBE_MAC_LOG_DIR/sentinel"

  export BLOCK_SHA
  export ALIAS_SHA
  BLOCK_SHA="$(printf '%s\n' 'managed line' | shasum -a 256 | awk '{print $1}')"
  ALIAS_SHA="$(shasum -a 256 "$HOME/.config/vibe-mac/aliases.zsh" |
    awk '{print $1}')"

  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
    manifest_record_package formulae owned-tool false true vibe-mac "" 1.0
    manifest_record_package formulae keep-tool true false homebrew 2.0 2.0
    manifest_record_package casks owned-app false true vibe-mac "" 3.0
    backup_file_once "$HOME/.zprofile" zprofile >/dev/null
    backup_file_once "$HOME/.config/vibe-mac/aliases.zsh" aliases-zsh >/dev/null
    manifest_record_file \
      zprofile .zprofile managed_block zprofile true true "$BLOCK_SHA" zprofile
    manifest_record_file \
      aliases .config/vibe-mac/aliases.zsh owned_file "" true true "$ALIAS_SHA" aliases-zsh
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" defaults.dock_autohide \
      "{\"domain\":\"com.apple.dock\",\"key\":\"autohide\",\"original_exists\":true,\"original_value\":false,\"applied_value\":true}"
  '

  export VIBE_MAC_BREW_STATE="$TEST_ROOT/brew-state"
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE="owned-tool keep-tool"
  export VIBE_MAC_TEST_UNINSTALL_CASKS="owned-app"
  export VIBE_MAC_DEFAULTS_STATE="$TEST_ROOT/defaults-state"
  export VIBE_MAC_DEFAULTS_BIN="$TEST_ROOT/fake-bin/defaults"
  export VIBE_MAC_KILLALL_BIN="$TEST_ROOT/fake-bin/killall"
  printf '%s\n' \
    "formula:owned-tool" \
    "formula:keep-tool" \
    "cask:owned-app" >"$VIBE_MAC_BREW_STATE"
  printf '%s\n' "com.apple.dock:autohide=true" >"$VIBE_MAC_DEFAULTS_STATE"

  make_fake_command brew '
    case "${1:-}" in
      list)
        if [ "${2:-}" = "--formula" ] && [ "${3:-}" = "--versions" ]; then
          case "${4:-}" in
            owned-tool) printf "%s\n" "owned-tool ${VIBE_MAC_OWNED_VERSION:-1.0}" ;;
            keep-tool) printf "%s\n" "keep-tool 2.0" ;;
            *) exit 1 ;;
          esac
        elif [ "${2:-}" = "--cask" ] && [ "${3:-}" = "--versions" ]; then
          [ "${4:-}" = owned-app ] || exit 1
          printf "%s\n" "owned-app 3.0"
        elif [ "${2:-}" = "--formula" ]; then
          grep -Fqx "formula:${3:-}" "$VIBE_MAC_BREW_STATE"
        elif [ "${2:-}" = "--cask" ]; then
          grep -Fqx "cask:${3:-}" "$VIBE_MAC_BREW_STATE"
        fi
        ;;
      uses)
        [ "${2:-}" = "--installed" ] || exit 2
        exit 0
        ;;
      uninstall)
        printf "brew:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
        if [ "${2:-}" = "--cask" ]; then
          item="cask:${3:-}"
        else
          item="formula:${2:-}"
        fi
        grep -Fvx "$item" "$VIBE_MAC_BREW_STATE" >"$VIBE_MAC_BREW_STATE.next" || true
        mv "$VIBE_MAC_BREW_STATE.next" "$VIBE_MAC_BREW_STATE"
        ;;
      --version)
        printf "%s\n" "Homebrew 5.0"
        ;;
    esac
  '
  make_fake_command defaults '
    printf "defaults:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    key="${2:-}:${3:-}"
    case "${1:-}" in
      read)
        line="$(grep -F "$key=" "$VIBE_MAC_DEFAULTS_STATE" | tail -n 1)" || exit 1
        printf "%s\n" "${line#*=}"
        ;;
      write)
        grep -Fv "$key=" "$VIBE_MAC_DEFAULTS_STATE" >"$VIBE_MAC_DEFAULTS_STATE.next" || true
        printf "%s=%s\n" "$key" "${5:-}" >>"$VIBE_MAC_DEFAULTS_STATE.next"
        mv "$VIBE_MAC_DEFAULTS_STATE.next" "$VIBE_MAC_DEFAULTS_STATE"
        ;;
      delete)
        grep -Fv "$key=" "$VIBE_MAC_DEFAULTS_STATE" >"$VIBE_MAC_DEFAULTS_STATE.next" || true
        mv "$VIBE_MAC_DEFAULTS_STATE.next" "$VIBE_MAC_DEFAULTS_STATE"
        ;;
    esac
  '
  make_fake_command killall \
    'printf "killall:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"'
}

add_owned_release() {
  local version release tree_sha archive_sha launcher id sha
  version=0.1.0-test
  release="$VIBE_MAC_RUNTIME_ROOT/releases/$version"
  archive_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$release" "$VIBE_MAC_RUNTIME_ROOT/bin"
  printf '%s\n' release >"$release/install.sh"
  chmod 0700 "$release/install.sh"
  tree_sha="$(/bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    release_tree_sha256 "$1"
  ' _ "$release")"
  printf '%s\n' "$archive_sha" >"$release/.bundle-sha256"
  printf '%s\n' "$tree_sha" >"$release/.bundle-tree-sha256"
  ln -s "releases/$version" "$VIBE_MAC_RUNTIME_ROOT/current"
  for id in verify doctor uninstall; do
    launcher="$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$id"
    printf '%s\n' "launcher $id" >"$launcher"
    chmod 0700 "$launcher"
    sha="$(shasum -a 256 "$launcher" | awk '{print $1}')"
    /bin/bash -c '
      source "$PROJECT_ROOT/lib/util.sh"
      json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" "launchers.$1" \
        "{\"path_kind\":\"runtime_relative\",\"path\":\"bin/vibe-mac-$1\",\"sha256\":\"$2\",\"owned\":true}"
    ' _ "$id" "$sha"
  done
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" releases.current \
      "{\"version\":\"$1\",\"path_kind\":\"runtime_relative\",\"path\":\"releases/$1\",\"archive_sha256\":\"$2\",\"tree_sha256\":\"$3\",\"owned\":true}"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" current_link \
      "{\"path_kind\":\"runtime_relative\",\"path\":\"current\",\"target\":\"releases/$1\",\"owned\":true}"
  ' _ "$version" "$archive_sha" "$tree_sha"
}

@test "uninstall по умолчанию строит zero-write план" {
  before_manifest="$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')"
  before_zprofile="$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/uninstall.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"План удаления"* ]]
  [ "$before_manifest" = "$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')" ]
  [ "$before_zprofile" = "$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')" ]
  assert_no_events
}

@test "uninstall --apply требует точное typed UNINSTALL" {
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  assert_no_events
  [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]
}

@test "uninstall удаляет только owned и сохраняет workspace backups logs" {
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew:uninstall owned-tool"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew:uninstall --cask owned-app"
  ! grep -F "keep-tool" "$VIBE_MAC_EVENT_LOG"
  assert_file_contains "$VIBE_MAC_DEFAULTS_STATE" "com.apple.dock:autohide=false"
  assert_file_contains "$HOME/.zprofile" "user line"
  ! grep -F "vibe-mac managed:zprofile" "$HOME/.zprofile"
  assert_path_absent "$HOME/.config/vibe-mac/aliases.zsh"
  [ -f "$HOME/dev/hello-vibe/sentinel" ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/test-install/sentinel" ]
  [ -f "$VIBE_MAC_LOG_DIR/sentinel" ]
}

@test "изменённый owned file остаётся как конфликт" {
  printf '%s\n' "user changed" >>"$HOME/.config/vibe-mac/aliases.zsh"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]
  [[ "$output" == *"конфликт"* ]]
}

@test "path traversal в manifest блокирует все изменения" {
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" files.aliases \
      "{\"path_kind\":\"home_relative\",\"path\":\"../outside\",\"kind\":\"owned_file\",\"block_id\":\"\",\"owned\":true,\"applied_sha\":\"$ALIAS_SHA\"}"
  '
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  assert_no_events
  [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]
}

@test "package version drift не удаляется и даёт конфликт" {
  export VIBE_MAC_OWNED_VERSION=9.9
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  ! grep -F "brew:uninstall owned-tool" "$VIBE_MAC_EVENT_LOG"
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
}

@test "подменённый backup блокирует apply до первого события" {
  printf '%s\n' tampered \
    >>"$VIBE_MAC_BACKUP_ROOT/test-install/zprofile.before"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  assert_no_events
  assert_file_contains "$HOME/.zprofile" "vibe-mac managed:zprofile"
}

@test "verified release удаляется через self-copy, state logs backups сохраняются" {
  add_owned_release
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/current"
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test"
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ]
  [ -f "$VIBE_MAC_LOG_DIR/sentinel" ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/test-install/sentinel" ]
  ! find "$TMPDIR" -maxdepth 1 -name 'vibe-mac-uninstall.*' | grep -q .

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"release bundle уже удалён"* ]]
}

@test "изменённый launcher блокирует весь apply до package/default writes" {
  add_owned_release
  printf '%s\n' tampered \
    >>"$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  assert_no_events
  [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
}
