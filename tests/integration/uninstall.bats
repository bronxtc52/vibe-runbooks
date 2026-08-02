#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"

  mkdir -p \
    "$HOME/.config/vibe-mac" \
    "$HOME/dev/hello-vibe" \
    "$VIBE_MAC_BACKUP_ROOT/test-install" \
    "$VIBE_MAC_LOG_DIR" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin"
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
  export VIBE_MAC_GIT_STATE="$TEST_ROOT/git-state"
  export VIBE_MAC_MISE_STATE="$TEST_ROOT/mise-state"
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
  : >"$VIBE_MAC_GIT_STATE"
  : >"$VIBE_MAC_MISE_STATE"

  make_fake_command brew '
    leaked="$(/usr/bin/env | /usr/bin/grep -E "^(HOMEBREW_|BASH_ENV=|ENV=)" | \
      /usr/bin/grep -Ev "^HOMEBREW_(NO_AUTO_UPDATE|NO_INSTALL_UPGRADE|NO_INSTALL_CLEANUP|NO_ENV_HINTS)=1$" || true)"
    extra_config_env="$(/usr/bin/env | \
      /usr/bin/grep -E "^(GIT_|CURL_|XDG_)" | /usr/bin/cut -d= -f1 | \
      /usr/bin/grep -Ev "^(GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|CURL_HOME|XDG_CONFIG_HOME)$" || true)"
    if [ -n "$leaked" ] || [ -n "$extra_config_env" ] ||
      [ "${GIT_CONFIG_GLOBAL:-}" != /dev/null ] ||
      [ "${GIT_CONFIG_NOSYSTEM:-}" != 1 ] ||
      [ "${CURL_HOME:-}" != /var/empty ] ||
      [ "${XDG_CONFIG_HOME:-}" != /var/empty ]; then
      printf "%s\n" brew-env-leak >>"$VIBE_MAC_EVENT_LOG"
    fi
    printf "brew-env:path=%s|tmp=%s|update=%s|upgrade=%s|cleanup=%s|git_global=%s|git_system=%s|curl=%s|xdg=%s\n" \
      "$PATH" \
      "${TMPDIR-unset}" \
      "${HOMEBREW_NO_AUTO_UPDATE-unset}" \
      "${HOMEBREW_NO_INSTALL_UPGRADE-unset}" \
      "${HOMEBREW_NO_INSTALL_CLEANUP-unset}" \
      "${GIT_CONFIG_GLOBAL-unset}" \
      "${GIT_CONFIG_NOSYSTEM-unset}" \
      "${CURL_HOME-unset}" \
      "${XDG_CONFIG_HOME-unset}" >>"$VIBE_MAC_EVENT_LOG"
    if command -v attacker-helper >/dev/null 2>&1; then
      attacker-helper
    fi
    case "${1:-}" in
      list)
        if [ "${2:-}" = "--formula" ] && [ "${3:-}" = "--versions" ]; then
          case "${4:-}" in
            owned-tool) printf "%s\n" "owned-tool ${VIBE_MAC_OWNED_VERSION:-1.0}" ;;
            keep-tool) printf "%s\n" "keep-tool 2.0" ;;
            git) printf "%s\n" "git 2.50.0" ;;
            mise) printf "%s\n" "mise 2026.8.0" ;;
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
        [ "${VIBE_MAC_TEST_BREW_USES_FAIL:-0}" != 1 ] || exit 8
        if [ "${VIBE_MAC_TEST_BREW_DEPENDENT:-0}" = 1 ]; then
          printf '%s\n' dependent-tool
        fi
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
  /bin/cp "$TEST_ROOT/fake-bin/brew" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  make_fake_command git '
    if /usr/bin/env | /usr/bin/grep -q "^GIT_"; then
      printf "%s\n" "git-env-leak" >>"$VIBE_MAC_EVENT_LOG"
    fi
    printf "git-env:config=%s|system=%s|dir=%s|work=%s|ceiling=%s\n" \
      "${GIT_CONFIG_GLOBAL-unset}" \
      "${GIT_CONFIG_SYSTEM-unset}" \
      "${GIT_DIR-unset}" \
      "${GIT_WORK_TREE-unset}" \
      "${GIT_CEILING_DIRECTORIES-unset}" >>"$VIBE_MAC_EVENT_LOG"
    case "${1:-}:${2:-}" in
      config:--global)
        case "${3:-}" in
          --get)
            line="$(grep -F "${4:-}=" "$VIBE_MAC_GIT_STATE" | tail -n 1)" || exit 1
            printf "%s\n" "${line#*=}"
            ;;
          --unset)
            printf "git:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
            grep -Fv "${4:-}=" "$VIBE_MAC_GIT_STATE" \
              >"$VIBE_MAC_GIT_STATE.next" || true
            mv "$VIBE_MAC_GIT_STATE.next" "$VIBE_MAC_GIT_STATE"
            ;;
        esac
        ;;
      --version:)
        printf "%s\n" "git version 2.50.0"
        ;;
    esac
  '
  /bin/cp "$TEST_ROOT/fake-bin/git" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/git"
  make_fake_command mise '
    config_root=
    if [ "${1:-}" = -C ]; then
      config_root="${2:-}"
      shift 2
    fi
    leaked="$(/usr/bin/env | /usr/bin/grep -E "^(MISE_|XDG_)" | \
      /usr/bin/cut -d= -f1 | \
      /usr/bin/grep -Ev "^(MISE_YES|MISE_CONFIG_DIR|MISE_GLOBAL_CONFIG_FILE|MISE_SYSTEM_CONFIG_FILE|MISE_DATA_DIR|MISE_CACHE_DIR|MISE_STATE_DIR|MISE_TMP_DIR)$" || true)"
    if [ -n "$leaked" ] ||
      [ "$config_root" != "${VIBE_MAC_TEST_TRUSTED_CONFIG_DIR:-missing}" ] ||
      [ "${MISE_CONFIG_DIR:-}" != "$config_root" ] ||
      [ "${MISE_GLOBAL_CONFIG_FILE:-}" != /dev/null ] ||
      [ "${MISE_SYSTEM_CONFIG_FILE:-}" != /dev/null ] ||
      [ "${MISE_DATA_DIR:-}" != "$HOME/.local/share/mise" ] ||
      [ "${MISE_CACHE_DIR:-}" != "$HOME/.cache/mise" ] ||
      [ "${MISE_STATE_DIR:-}" != "$HOME/.local/state/mise" ] ||
      [ "${MISE_TMP_DIR:-}" != "$TMPDIR" ]; then
      printf "%s\n" "mise-env-leak" >>"$VIBE_MAC_EVENT_LOG"
    fi
    printf "mise-env:data=%s|cache=%s|config=%s|global=%s|system=%s|state=%s|tmp=%s|xdg_config=%s|xdg_data=%s|xdg_cache=%s|xdg_state=%s|node=%s|python=%s|backend=%s\n" \
      "${MISE_DATA_DIR-unset}" \
      "${MISE_CACHE_DIR-unset}" \
      "${MISE_CONFIG_DIR-unset}" \
      "${MISE_GLOBAL_CONFIG_FILE-unset}" \
      "${MISE_SYSTEM_CONFIG_FILE-unset}" \
      "${MISE_STATE_DIR-unset}" \
      "${MISE_TMP_DIR-unset}" \
      "${XDG_CONFIG_HOME-unset}" \
      "${XDG_DATA_HOME-unset}" \
      "${XDG_CACHE_HOME-unset}" \
      "${XDG_STATE_HOME-unset}" \
      "${MISE_NODE_MIRROR_URL-unset}" \
      "${MISE_PYTHON_COMPILE-unset}" \
      "${MISE_BACKENDS-unset}" >>"$VIBE_MAC_EVENT_LOG"
    printf "mise:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    case "${1:-}" in
      --version)
        printf "%s\n" "mise 2026.8.0"
        ;;
      where)
        item="${2:-}"
        grep -Fqx "$item" "$VIBE_MAC_MISE_STATE" || exit 1
        if [ -n "${VIBE_MAC_TEST_MISE_WHERE_OVERRIDE:-}" ]; then
          printf "%s\n" "$VIBE_MAC_TEST_MISE_WHERE_OVERRIDE"
        else
          name="${item%@*}"
          version="${item#*@}"
          printf "%s\n" "$HOME/.local/share/mise/installs/$name/$version"
        fi
        ;;
      exec)
        item="${2:-}"
        grep -Fqx "$item" "$VIBE_MAC_MISE_STATE" || exit 1
        name="${item%@*}"
        version="${item#*@}"
        case "$name" in
          node) printf "%s\n" "${VIBE_MAC_TEST_MISE_VERSION_OVERRIDE:-v$version}" ;;
          python) printf "%s\n" "${VIBE_MAC_TEST_MISE_VERSION_OVERRIDE:-Python $version}" ;;
          *) exit 2 ;;
        esac
        ;;
      uninstall)
        item="${2:-}"
        grep -Fvx "$item" "$VIBE_MAC_MISE_STATE" \
          >"$VIBE_MAC_MISE_STATE.next" || true
        mv "$VIBE_MAC_MISE_STATE.next" "$VIBE_MAC_MISE_STATE"
        name="${item%@*}"
        version="${item#*@}"
        root="$HOME/.local/share/mise/installs/$name/$version"
        if [ -d "$root" ] && [ ! -L "$root" ]; then
          /usr/bin/find "$root" -depth -delete
          /bin/rmdir "$HOME/.local/share/mise/installs/$name" 2>/dev/null || true
        fi
        ;;
    esac
  '
  /bin/cp "$TEST_ROOT/fake-bin/mise" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"
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

record_runtime() {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_runtime "$1" "$2" "$3" "$4"
  ' _ "$1" "$2" "$3" "$4"
  if [ "$3:$4" = false:true ]; then
    proof="$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-$1.created"
    printf '%s|%s|.local/share/mise/installs/%s/%s\n' \
      "$1" "$2" "$1" "$2" >"$proof"
    /bin/chmod 0600 "$proof"
  fi
}

add_installed_runtime() {
  local name version root
  name="$1"
  version="$2"
  root="$HOME/.local/share/mise/installs/$name/$version"
  /bin/mkdir -p "$root/bin"
  printf '%s\n' "$name@$version" >>"$VIBE_MAC_MISE_STATE"
  if ! /usr/bin/grep -Fqx 'formula:mise' "$VIBE_MAC_BREW_STATE"; then
    printf '%s\n' 'formula:mise' >>"$VIBE_MAC_BREW_STATE"
  fi
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

prepare_packaged_uninstall_release() {
  local release tree_sha build_commit
  build_commit=0123456789012345678901234567890123456789
  HOME="$(cd "$HOME" && pwd -P)"
  export HOME
  export VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
  release="$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-packaged"
  mkdir -p "$release/config" "$release/lib"
  /usr/bin/sed \
    "s|'\$Format:%H\$'|'$build_commit'|" \
    "$PROJECT_ROOT/uninstall.sh" >"$release/uninstall.sh"
  /bin/cp "$PROJECT_ROOT/config/versions.env" \
    "$release/config/versions.env"
  /bin/cp "$PROJECT_ROOT/lib/util.sh" "$release/lib/util.sh"
  /bin/cp "$PROJECT_ROOT/lib/ui.sh" "$release/lib/ui.sh"
  /bin/cp "$PROJECT_ROOT/lib/guard.sh" "$release/lib/guard.sh"
  /bin/chmod 0700 "$release/uninstall.sh"
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
  PACKAGED_UNINSTALL_ROOT="$release"
}

prepare_packaged_internal_uninstall_runtime() {
  local created parent physical_root relative build_commit sha
  build_commit=0123456789012345678901234567890123456789
  created="$(/usr/bin/mktemp -d /tmp/vibe-mac-uninstall.XXXXXX)"
  parent="$(cd "${created%/*}" && pwd -P)"
  physical_root="$parent/${created##*/}"
  mkdir -p "$physical_root/config" "$physical_root/lib"
  /usr/bin/sed \
    "s|'\$Format:%H\$'|'$build_commit'|" \
    "$PROJECT_ROOT/uninstall.sh" >"$physical_root/uninstall.sh"
  /bin/cp "$PROJECT_ROOT/config/versions.env" \
    "$physical_root/config/versions.env"
  /bin/cp "$PROJECT_ROOT/lib/guard.sh" "$physical_root/lib/guard.sh"
  /bin/cp "$PROJECT_ROOT/lib/ui.sh" "$physical_root/lib/ui.sh"
  /bin/cp "$PROJECT_ROOT/lib/util.sh" "$physical_root/lib/util.sh"
  printf '%s\n' \
    '[ "${VIBE_MAC_TEST_MODE:-}" = 0 ] || exit 19' \
    ': >"$HOME/presource-internal-uninstall-sentinel"' \
    'exit 17' >>"$physical_root/lib/util.sh"
  /bin/chmod 0700 "$physical_root/uninstall.sh"
  /bin/chmod 0600 \
    "$physical_root/config/versions.env" \
    "$physical_root/lib/guard.sh" \
    "$physical_root/lib/ui.sh" \
    "$physical_root/lib/util.sh"
  : >"$physical_root/.runtime-sha256"
  for relative in \
    uninstall.sh \
    config/versions.env \
    lib/guard.sh \
    lib/ui.sh \
    lib/util.sh; do
    sha="$(shasum -a 256 "$physical_root/$relative" | awk '{print $1}')"
    printf '%s  %s\n' "$sha" "$relative" \
      >>"$physical_root/.runtime-sha256"
  done
  PACKAGED_INTERNAL_UNINSTALL_ROOT="$physical_root"
  PACKAGED_INTERNAL_UNINSTALL_MANIFEST_SHA="$(shasum -a 256 \
    "$physical_root/.runtime-sha256" | awk '{print $1}')"
}

refresh_packaged_internal_uninstall_manifest() {
  local relative sha
  : >"$PACKAGED_INTERNAL_UNINSTALL_ROOT/.runtime-sha256"
  for relative in \
    uninstall.sh \
    config/versions.env \
    lib/guard.sh \
    lib/ui.sh \
    lib/util.sh; do
    sha="$(shasum -a 256 \
      "$PACKAGED_INTERNAL_UNINSTALL_ROOT/$relative" | awk '{print $1}')"
    printf '%s  %s\n' "$sha" "$relative" \
      >>"$PACKAGED_INTERNAL_UNINSTALL_ROOT/.runtime-sha256"
  done
  PACKAGED_INTERNAL_UNINSTALL_MANIFEST_SHA="$(shasum -a 256 \
    "$PACKAGED_INTERNAL_UNINSTALL_ROOT/.runtime-sha256" | awk '{print $1}')"
}

inject_internal_find_failure() {
  local stage fake_find script next
  stage="$1"
  fake_find="$2"
  script="$PACKAGED_INTERNAL_UNINSTALL_ROOT/uninstall.sh"
  next="$script.next"
  /usr/bin/awk -v stage="$stage" -v fake_find="$fake_find" '
    stage == "layout" &&
      index($0, "if ! /usr/bin/find") &&
      index($0, "-mindepth 1 -print0") {
        sub("/usr/bin/find", fake_find)
        replaced += 1
      }
    stage == "symlink" &&
      index($0, "symlinks=\"$(/usr/bin/find") &&
      index($0, "-type l -print -quit") {
        sub("/usr/bin/find", fake_find)
        replaced += 1
      }
    { print }
    END { if (replaced != 1) exit 2 }
  ' "$script" >"$next"
  /bin/mv "$next" "$script"
  /bin/chmod 0700 "$script"
  refresh_packaged_internal_uninstall_manifest
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

@test "packaged uninstall проверяет release tree до source tampered util" {
  prepare_packaged_uninstall_release
  printf '%s\n' ': >"$HOME/presource-uninstall-sentinel"' \
    >>"$PACKAGED_UNINSTALL_ROOT/lib/util.sh"

  run /bin/bash "$PACKAGED_UNINSTALL_ROOT/uninstall.sh" --dry-run

  [ "$status" -eq 2 ]
  assert_path_absent "$HOME/presource-uninstall-sentinel"
}

@test "packaged internal uninstall после runtime manifest не требует release tree" {
  prepare_packaged_internal_uninstall_runtime

  run /usr/bin/env \
    VIBE_MAC_TEST_MODE=1 \
    VIBE_MAC_UNINSTALL_RUNTIME_MANIFEST_SHA256="$PACKAGED_INTERNAL_UNINSTALL_MANIFEST_SHA" \
    /bin/bash "$PACKAGED_INTERNAL_UNINSTALL_ROOT/uninstall.sh" \
    --internal-apply
  /usr/bin/find "$PACKAGED_INTERNAL_UNINSTALL_ROOT" -depth -delete

  [ "$status" -eq 17 ]
  [ -f "$HOME/presource-internal-uninstall-sentinel" ]
}

@test "internal uninstall отклоняет find failure в обоих layout scans" {
  local stage fake_find
  fake_find="$TEST_ROOT/failing-find"
  printf '%s\n' '#!/bin/bash' 'exit 47' >"$fake_find"
  /bin/chmod 0700 "$fake_find"

  for stage in layout symlink; do
    prepare_packaged_internal_uninstall_runtime
    inject_internal_find_failure "$stage" "$fake_find"

    run /usr/bin/env \
      VIBE_MAC_UNINSTALL_RUNTIME_MANIFEST_SHA256="$PACKAGED_INTERNAL_UNINSTALL_MANIFEST_SHA" \
      /bin/bash "$PACKAGED_INTERNAL_UNINSTALL_ROOT/uninstall.sh" \
      --internal-apply
    /usr/bin/find "$PACKAGED_INTERNAL_UNINSTALL_ROOT" -depth -delete

    [ "$status" -eq 2 ]
    [[ "$output" == *"integrity-проверку"* ]]
    assert_path_absent "$HOME/presource-internal-uninstall-sentinel"
  done
}

@test "packaged uninstall default и dry-run pre-source остаются zero-write" {
  local mode before after
  local -a args sandbox_argv
  prepare_packaged_uninstall_release
  printf '%s\n' 'exit 17' >>"$PACKAGED_UNINSTALL_ROOT/lib/util.sh"
  tree_sha="$(/bin/bash -c '
    source "$1/lib/util.sh"
    release_tree_sha256 "$2"
  ' _ "$PROJECT_ROOT" "$PACKAGED_UNINSTALL_ROOT")"
  printf '%s\n' "$tree_sha" \
    >"$PACKAGED_UNINSTALL_ROOT/.bundle-tree-sha256"
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

  for mode in default dry-run; do
    args=()
    if [ "$mode" = dry-run ]; then
      args=(--dry-run)
    fi
    run /usr/bin/env \
      TMPDIR="$TEST_ROOT/unwritable-tmp" \
      "${sandbox_argv[@]}" \
      /bin/bash "$PACKAGED_UNINSTALL_ROOT/uninstall.sh" "${args[@]}"
    [ "$status" -eq 17 ]
  done
  after="$(/usr/bin/find "$TEST_ROOT/unwritable-tmp" -print |
    LC_ALL=C /usr/bin/sort | shasum -a 256 | awk '{print $1}')"
  chmod 0700 "$TEST_ROOT/unwritable-tmp"

  [ "$before" = "$after" ]
  run /usr/bin/grep -F 'vibe-mac.uninstall-integrity.' \
    "$PROJECT_ROOT/uninstall.sh"
  [ "$status" -eq 1 ]
}

@test "uninstall dry-run показывает owned runtimes и ничего не меняет" {
  record_runtime node 24.18.1 false true
  record_runtime python 3.12.13 false true
  add_installed_runtime node 24.18.1
  add_installed_runtime python 3.12.13

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime: node@24.18.1"* ]]
  [[ "$output" == *"runtime: python@3.12.13"* ]]
  [ -d "$HOME/.local/share/mise/installs/node/24.18.1" ]
  [ -d "$HOME/.local/share/mise/installs/python/3.12.13" ]
  assert_file_contains "$VIBE_MAC_MISE_STATE" "node@24.18.1"
  assert_file_contains "$VIBE_MAC_MISE_STATE" "python@3.12.13"
  assert_no_events
}

@test "uninstall удаляет exact owned runtimes до owned formula mise" {
  record_runtime node 24.18.1 false true
  record_runtime python 3.12.13 false true
  add_installed_runtime node 24.18.1
  add_installed_runtime python 3.12.13
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_package formulae mise false true vibe-mac "" 2026.8.0
  '
  printf '%s\n' 'formula:mise' >>"$VIBE_MAC_BREW_STATE"
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=mise
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  assert_path_absent "$HOME/.local/share/mise/installs/node/24.18.1"
  assert_path_absent "$HOME/.local/share/mise/installs/python/3.12.13"
  run /usr/bin/grep -Fqx 'node@24.18.1' "$VIBE_MAC_MISE_STATE"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fqx 'python@3.12.13' "$VIBE_MAC_MISE_STATE"
  [ "$status" -ne 0 ]
  node_line="$(/usr/bin/grep -nF 'mise:uninstall node@24.18.1' \
    "$VIBE_MAC_EVENT_LOG" | /usr/bin/cut -d: -f1)"
  python_line="$(/usr/bin/grep -nF 'mise:uninstall python@3.12.13' \
    "$VIBE_MAC_EVENT_LOG" | /usr/bin/cut -d: -f1)"
  brew_line="$(/usr/bin/grep -nF 'brew:uninstall mise' \
    "$VIBE_MAC_EVENT_LOG" | /usr/bin/cut -d: -f1)"
  [ -n "$node_line" ]
  [ -n "$python_line" ]
  [ -n "$brew_line" ]
  [ "$node_line" -lt "$brew_line" ]
  [ "$python_line" -lt "$brew_line" ]
}

@test "uninstall удаляет owned runtime, но сохраняет mise для extra runtime" {
  record_runtime node 24.18.1 false true
  add_installed_runtime node 24.18.1
  mkdir -p "$HOME/.local/share/mise/installs/ruby/3.4.1/bin"
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_package formulae mise false true vibe-mac "" 2026.8.0
  '
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=mise
  export VIBE_MAC_TEST_UNINSTALL_CASKS=none
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  assert_path_absent "$HOME/.local/share/mise/installs/node/24.18.1"
  [ -d "$HOME/.local/share/mise/installs/ruby/3.4.1" ]
  assert_file_contains "$VIBE_MAC_BREW_STATE" 'formula:mise'
  assert_file_contains "$VIBE_MAC_EVENT_LOG" 'mise:uninstall node@24.18.1'
  run /usr/bin/grep -Fq 'brew:uninstall mise' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall сохраняет preexisting runtime и owned formula mise" {
  record_runtime node 24.18.1 true false
  add_installed_runtime node 24.18.1
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_package formulae mise false true vibe-mac "" 2026.8.0
  '
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=mise
  export VIBE_MAC_TEST_UNINSTALL_CASKS=none
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"Formula mise"* ]]
  [ -d "$HOME/.local/share/mise/installs/node/24.18.1" ]
  assert_file_contains "$VIBE_MAC_MISE_STATE" "node@24.18.1"
  assert_file_contains "$VIBE_MAC_BREW_STATE" 'formula:mise'
  run /usr/bin/grep -Fq 'mise:uninstall node@24.18.1' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fq 'brew:uninstall mise' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall сохраняет owned mise при extra runtime вне manifest" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_package formulae mise false true vibe-mac "" 2026.8.0
  '
  mkdir -p "$HOME/.local/share/mise/installs/ruby/3.4.1/bin"
  printf '%s\n' 'formula:mise' >>"$VIBE_MAC_BREW_STATE"
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=mise
  export VIBE_MAC_TEST_UNINSTALL_CASKS=none
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"Formula mise"* ]]
  [ -d "$HOME/.local/share/mise/installs/ruby/3.4.1" ]
  assert_file_contains "$VIBE_MAC_BREW_STATE" 'formula:mise'
  run /usr/bin/grep -Fq 'brew:uninstall mise' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall сохраняет owned runtime при drift и не удаляет mise" {
  record_runtime node 24.18.1 false true
  add_installed_runtime node 24.18.1
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_package formulae mise false true vibe-mac "" 2026.8.0
  '
  printf '%s\n' 'formula:mise' >>"$VIBE_MAC_BREW_STATE"
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=mise
  export VIBE_MAC_TEST_MISE_VERSION_OVERRIDE=v99.0.0
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"runtime node@24.18.1"* ]]
  [ -d "$HOME/.local/share/mise/installs/node/24.18.1" ]
  assert_file_contains "$VIBE_MAC_MISE_STATE" "node@24.18.1"
  assert_file_contains "$VIBE_MAC_BREW_STATE" 'formula:mise'
  run /usr/bin/grep -Fq 'mise:uninstall node@24.18.1' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fq 'brew:uninstall mise' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall игнорирует PATH mise и сохраняет runtime при path drift" {
  record_runtime node 24.18.1 false true
  add_installed_runtime node 24.18.1
  make_fake_command mise '
    printf "%s\n" "trojan:mise:$*" >>"$VIBE_MAC_EVENT_LOG"
    exit 99
  '
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=keep-tool
  export VIBE_MAC_TEST_UNINSTALL_CASKS=none
  export VIBE_MAC_TEST_MISE_WHERE_OVERRIDE="$TEST_ROOT/unexpected-node"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"runtime node@24.18.1"* ]]
  [ -d "$HOME/.local/share/mise/installs/node/24.18.1" ]
  assert_file_contains "$VIBE_MAC_MISE_STATE" "node@24.18.1"
  run /usr/bin/grep -Fq 'trojan:mise:' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fq 'mise:uninstall node@24.18.1' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "invalid typed runtime manifest блокирует план и mutations" {
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" runtimes.node.owned "$1"
  ' _ '"true"'
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" != *"План удаления"* ]]
  assert_no_events
  [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]
}

@test "forged string true в owned file блокирует uninstall до mutations" {
  run "$VIBE_MAC_PLUTIL_BIN" \
    -replace files.aliases.owned -string true "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" != *"План удаления"* ]]
  assert_no_events
  [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
  assert_file_contains "$VIBE_MAC_BREW_STATE" "cask:owned-app"
}

@test "forged string true в owned package блокирует uninstall до mutations" {
  run "$VIBE_MAC_PLUTIL_BIN" \
    -replace packages.formulae.owned-tool.owned -string true \
    "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" != *"План удаления"* ]]
  assert_no_events
  [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
  assert_file_contains "$VIBE_MAC_BREW_STATE" "cask:owned-app"
}

@test "owned runtime без private creation proof блокирует uninstall" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_runtime node "$NODE_VERSION" false true
  '
  add_installed_runtime node 24.18.1
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" != *"План удаления"* ]]
  assert_no_events
  [ -d "$HOME/.local/share/mise/installs/node/24.18.1" ]
}

@test "uninstall не передаёт hostile mise XDG backend mirror и config env" {
  record_runtime node 24.18.1 false true
  add_installed_runtime node 24.18.1
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=keep-tool
  export VIBE_MAC_TEST_UNINSTALL_CASKS=none
  export MISE_DATA_DIR="$TEST_ROOT/hostile-mise-data"
  export MISE_CACHE_DIR="$TEST_ROOT/hostile-mise-cache"
  export MISE_CONFIG_DIR="$TEST_ROOT/hostile-mise-config"
  export MISE_GLOBAL_CONFIG_FILE="$TEST_ROOT/hostile-mise-global.toml"
  export XDG_CONFIG_HOME="$TEST_ROOT/hostile-xdg"
  export XDG_DATA_HOME="$TEST_ROOT/hostile-xdg-data"
  export XDG_CACHE_HOME="$TEST_ROOT/hostile-xdg-cache"
  export XDG_STATE_HOME="$TEST_ROOT/hostile-xdg-state"
  export MISE_NODE_MIRROR_URL="https://hostile.invalid/node"
  export MISE_PYTHON_COMPILE=hostile
  export MISE_BACKENDS=hostile
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  assert_path_absent "$HOME/.local/share/mise/installs/node/24.18.1"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "mise-env:data=$HOME/.local/share/mise|cache=$HOME/.cache/mise|config="
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "|global=/dev/null|system=/dev/null|state=$HOME/.local/state/mise|tmp=$TMPDIR|"
  run /usr/bin/grep -Fq 'mise-env-leak' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fq hostile "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
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

@test "uninstall игнорирует PATH trojan для destructive brew calls" {
  make_fake_command brew '
    printf "%s\n" "trojan:brew:$*" >>"$VIBE_MAC_EVENT_LOG"
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew" "$@"
  '
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  run /usr/bin/grep -Fq 'trojan:brew:' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew:uninstall owned-tool"
}

@test "uninstall блокирует Homebrew executable symlink наружу" {
  outside="$TEST_ROOT/outside-brew"
  /bin/mv "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew" "$outside"
  /bin/ln -s "$outside" "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --dry-run
  [ "$status" -eq 0 ]
  : >"$VIBE_MAC_EVENT_LOG"
  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"Destructive tool provenance"* ]]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
  run /usr/bin/grep -Fq 'brew:uninstall' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall считает dangling Homebrew symlink integrity error" {
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  /bin/ln -s ../Cellar/brew/missing/bin/brew \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --dry-run
  [ "$status" -eq 0 ]
  : >"$VIBE_MAC_EVENT_LOG"
  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"Destructive tool provenance"* ]]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
  run /usr/bin/grep -Fq 'brew:uninstall' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall принимает canonical symlink внутрь Homebrew Cellar" {
  cellar_brew="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/brew/5.0/bin/brew"
  /bin/mkdir -p "${cellar_brew%/*}"
  /bin/mv "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew" "$cellar_brew"
  /bin/ln -s ../Cellar/brew/5.0/bin/brew \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --dry-run
  [ "$status" -eq 0 ]
  : >"$VIBE_MAC_EVENT_LOG"
  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew:uninstall owned-tool"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew:uninstall --cask owned-app"
}

@test "uninstall блокирует непустой Homebrew brew.env" {
  env_file="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/etc/homebrew/brew.env"
  /bin/mkdir -p "${env_file%/*}"
  printf '%s\n' 'HOMEBREW_API_DOMAIN=https://attacker.invalid' >"$env_file"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --dry-run
  [ "$status" -eq 0 ]
  : >"$VIBE_MAC_EVENT_LOG"
  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"Destructive tool provenance"* ]]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
  run /usr/bin/grep -Fq 'brew:uninstall' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall запускает Homebrew с clean safe environment" {
  make_fake_command attacker-helper \
    'printf "%s\n" attacker-path-executed >>"$VIBE_MAC_EVENT_LOG"'
  export HOMEBREW_API_DOMAIN=https://attacker.invalid/api
  export HOMEBREW_BOTTLE_DOMAIN=https://attacker.invalid/bottles
  export HOMEBREW_BREW_GIT_REMOTE=https://attacker.invalid/brew.git
  export HOMEBREW_CORE_GIT_REMOTE=https://attacker.invalid/core.git
  export HOMEBREW_CASK_OPTS=--zap
  export HOMEBREW_GITHUB_API_TOKEN=attacker-token
  export GIT_CONFIG_GLOBAL="$TEST_ROOT/attacker.gitconfig"
  export GIT_CONFIG_NOSYSTEM=0
  export GIT_EXEC_PATH="$TEST_ROOT/attacker-git-exec"
  export CURL_HOME="$TEST_ROOT/attacker-curl"
  export XDG_CONFIG_HOME="$TEST_ROOT/attacker-xdg"
  export TMPDIR="$TEST_ROOT/attacker-tmp"
  /bin/mkdir -p "$TMPDIR"
  export VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR=1
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  run /usr/bin/grep -Fq brew-env-leak "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fq attacker-path-executed "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Ev \
    "^brew-env:path=$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin\\|tmp=/tmp\\|update=1\\|upgrade=1\\|cleanup=1\\|git_global=/dev/null\\|git_system=1\\|curl=/var/empty\\|xdg=/var/empty$" \
    <(/usr/bin/grep '^brew-env:' "$VIBE_MAC_EVENT_LOG")
  [ "$status" -ne 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" 'brew:uninstall owned-tool'
  assert_file_contains "$VIBE_MAC_EVENT_LOG" 'brew:uninstall --cask owned-app'
}

@test "uninstall self-copy не исполняет inherited BASH_ENV payload" {
  stage_one="$TEST_ROOT/bash-env-stage-one"
  payload="$TEST_ROOT/bash-env-payload"
  printf 'export BASH_ENV=%q\nexport ENV=%q\n' \
    "$payload" "$payload" >"$stage_one"
  printf '%s\n' \
    'printf "%s\n" selfcopy-bash-env-payload >>"$VIBE_MAC_EVENT_LOG"' \
    >"$payload"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /usr/bin/env BASH_ENV="$stage_one" \
    /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  run /usr/bin/grep -Fq selfcopy-bash-env-payload "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "uninstall игнорирует PATH trojan для destructive git calls" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_git_default pull-rebase pull.rebase true
  '
  printf '%s\n' 'pull.rebase=true' >"$VIBE_MAC_GIT_STATE"
  make_fake_command git '
    printf "%s\n" "trojan:git:$*" >>"$VIBE_MAC_EVENT_LOG"
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/git" "$@"
  '
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  run /usr/bin/grep -Fq 'trojan:git:' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "git:config --global --unset pull.rebase"
}

@test "uninstall запускает Git с clean environment" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_git_default pull-rebase pull.rebase true
  '
  printf '%s\n' 'pull.rebase=true' >"$VIBE_MAC_GIT_STATE"
  export GIT_CONFIG_GLOBAL="$TEST_ROOT/hostile.gitconfig"
  export GIT_CONFIG_SYSTEM="$TEST_ROOT/hostile-system.gitconfig"
  export GIT_DIR="$TEST_ROOT/hostile.git"
  export GIT_WORK_TREE="$TEST_ROOT/hostile-worktree"
  export GIT_CEILING_DIRECTORIES="$TEST_ROOT"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  run /usr/bin/grep -Ev \
    '^git-env:config=unset\|system=unset\|dir=unset\|work=unset\|ceiling=unset$' \
    <(/usr/bin/grep '^git-env:' "$VIBE_MAC_EVENT_LOG")
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fq 'git-env-leak' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -Fq 'pull.rebase=true' "$VIBE_MAC_GIT_STATE"
  [ "$status" -ne 0 ]
}

@test "uninstall удаляет Git defaults до owned Homebrew Git" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_package formulae git false true vibe-mac "" 2.50.0
    manifest_record_git_default pull-rebase pull.rebase true
  '
  printf '%s\n' 'formula:git' >>"$VIBE_MAC_BREW_STATE"
  printf '%s\n' 'pull.rebase=true' >"$VIBE_MAC_GIT_STATE"
  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=git
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  git_line="$(/usr/bin/grep -nF \
    'git:config --global --unset pull.rebase' "$VIBE_MAC_EVENT_LOG" | /usr/bin/cut -d: -f1)"
  brew_line="$(/usr/bin/grep -nF \
    'brew:uninstall git' "$VIBE_MAC_EVENT_LOG" | /usr/bin/cut -d: -f1)"
  [ -n "$git_line" ]
  [ -n "$brew_line" ]
  [ "$git_line" -lt "$brew_line" ]
}

@test "недоступный exact Homebrew Git сохраняет owned Git defaults" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_record_git_default pull-rebase pull.rebase true
  '
  printf '%s\n' 'pull.rebase=true' >"$VIBE_MAC_GIT_STATE"
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/git"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"Homebrew Git недоступен"* ]]
  assert_file_contains "$VIBE_MAC_GIT_STATE" 'pull.rebase=true'
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

@test "недоступный Homebrew сохраняет owned packages и даёт exit 1" {
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"Homebrew недоступен"* ]]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
  assert_file_contains "$VIBE_MAC_BREW_STATE" "cask:owned-app"
}

@test "непроверенные dependents сохраняют formula и дают exit 1" {
  export VIBE_MAC_TEST_BREW_USES_FAIL=1
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"dependents"* ]]
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

@test "destructive apply реально re-exec из проверенного temp runtime" {
  local temp_parent uninstall_output
  add_owned_release
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL
  temp_parent="$(cd "$TMPDIR" && pwd -P)"

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 0 ]
  uninstall_output="$output"
  run /usr/bin/grep -E \
    "^uninstall-runtime:$temp_parent/vibe-mac-uninstall\\.[A-Za-z0-9]+$" \
    "$VIBE_MAC_EVENT_LOG"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$uninstall_output" | \
    /usr/bin/grep -c 'Введи UNINSTALL:')" -eq 1 ]
  assert_path_absent "$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test"
  ! find "$TMPDIR" -maxdepth 1 -name 'vibe-mac-uninstall.*' | grep -q .
}

@test "internal apply нельзя запустить вне проверенного temp runtime" {
  add_owned_release
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --internal-apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"integrity-проверку"* ]]
  assert_no_events
  [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ]
  [ -f "$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test/install.sh" ]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
}

@test "tampered temp dependency блокируется до source и mutations" {
  local runtime relative manifest_sha copy_sha
  runtime="$(/usr/bin/mktemp -d "$TMPDIR/vibe-mac-uninstall.XXXXXX")"
  /bin/mkdir "$runtime/config" "$runtime/lib"
  : >"$runtime/.runtime-sha256"
  for relative in \
    uninstall.sh \
    config/versions.env \
    lib/guard.sh \
    lib/ui.sh \
    lib/util.sh; do
    /bin/cp "$PROJECT_ROOT/$relative" "$runtime/$relative"
    copy_sha="$(/usr/bin/shasum -a 256 "$runtime/$relative" | \
      /usr/bin/awk '{print $1}')"
    printf '%s  %s\n' "$copy_sha" "$relative" \
      >>"$runtime/.runtime-sha256"
  done
  printf '%s\n' \
    'printf "tampered-source\\n" >>"$VIBE_MAC_EVENT_LOG"' \
    >>"$runtime/lib/util.sh"
  manifest_sha="$(/usr/bin/shasum -a 256 "$runtime/.runtime-sha256" | \
    /usr/bin/awk '{print $1}')"

  run /usr/bin/env \
    VIBE_MAC_UNINSTALL_RUNTIME_MANIFEST_SHA256="$manifest_sha" \
    /bin/bash "$runtime/uninstall.sh" --internal-apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"integrity-проверку"* ]]
  assert_no_events
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
}

@test "unexpected temp entry делает cleanup fail-closed" {
  local runtime
  /bin/mv \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew.real"
  make_fake_command brew '
    if [ "${1:-}" = uninstall ]; then
      printf "%s\n" intruder >"$VIBE_MAC_ROOT/unexpected"
    fi
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew.real" "$@"
  '
  /bin/cp "$TEST_ROOT/fake-bin/brew" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected entries"* ]]
  runtime="$(find "$TMPDIR" -maxdepth 1 -type d \
    -name 'vibe-mac-uninstall.*' -print -quit)"
  [ -n "$runtime" ]
  [ -f "$runtime/unexpected" ]
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

@test "symlink ancestor release блокирует uninstall до любых изменений" {
  add_owned_release
  outside="$TEST_ROOT/outside-releases"
  /bin/mv "$VIBE_MAC_RUNTIME_ROOT/releases" "$outside"
  ln -s "$outside" "$VIBE_MAC_RUNTIME_ROOT/releases"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  assert_no_events
  [ -f "$outside/0.1.0-test/install.sh" ]
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
}

@test "некорректный actionable default блокирует план и все mutation events" {
  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' "owned omz" >"$HOME/.oh-my-zsh/sentinel"
  omz_sha="$(/bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    tree_sha256 "$1"
  ' _ "$HOME/.oh-my-zsh")"
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" components.oh_my_zsh \
      "{\"preexisting\":false,\"owned\":true,\"version_before\":\"\",\"version_after\":\"test\",\"tree_sha256\":\"$1\"}"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" defaults.finder_extensions \
      "{\"domain\":\"NSGlobalDomain\",\"key\":\"AppleShowAllExtensions\",\"original_exists\":\"not-bool\",\"original_value\":false,\"applied_value\":true}"
  ' _ "$omz_sha"
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply

  [ "$status" -eq 2 ]
  [[ "$output" != *"План удаления"* ]]
  assert_no_events
  assert_file_contains "$VIBE_MAC_BREW_STATE" "formula:owned-tool"
  assert_file_contains "$VIBE_MAC_BREW_STATE" "cask:owned-app"
  assert_file_contains "$VIBE_MAC_DEFAULTS_STATE" \
    "com.apple.dock:autohide=true"
  assert_file_contains "$HOME/.zprofile" "vibe-mac managed:zprofile"
  [ -f "$HOME/.config/vibe-mac/aliases.zsh" ]
  [ -f "$HOME/.oh-my-zsh/sentinel" ]
}
