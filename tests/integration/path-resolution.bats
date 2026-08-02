#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  HOSTILE_BIN="$TEST_ROOT/hostile-bin"
  ENTRYPOINT_FIXTURE="$TEST_ROOT/entrypoints"
  STEP_FIXTURE_ROOT="$TEST_ROOT/step-fixture"
  mkdir -p "$HOSTILE_BIN" "$ENTRYPOINT_FIXTURE" \
    "$STEP_FIXTURE_ROOT/steps"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' ': >"$RESOLUTION_SENTINEL"'
    printf '%s\n' '/usr/bin/dirname "$@"'
  } >"$HOSTILE_BIN/dirname"
  chmod 0700 "$HOSTILE_BIN/dirname"
}

copy_entrypoint_with_invalid_release_marker() {
  local name variable destination
  name="$1"
  destination="$ENTRYPOINT_FIXTURE/$name.sh"
  case "$name" in
    install) variable=VIBE_MAC_INSTALL_BUILD_COMMIT ;;
    verify) variable=VIBE_MAC_VERIFY_BUILD_COMMIT ;;
    doctor) variable=VIBE_MAC_DOCTOR_BUILD_COMMIT ;;
    uninstall) variable=VIBE_MAC_UNINSTALL_BUILD_COMMIT ;;
    *) return 2 ;;
  esac
  /usr/bin/sed \
    "s|$variable='\$Format:%H\$'|$variable='invalid-release-marker'|" \
    "$PROJECT_ROOT/$name.sh" >"$destination"
  chmod 0700 "$destination"
  printf '%s\n' "$destination"
}

run_with_imported_resolution_functions() {
  local target sentinel
  target="$1"
  sentinel="$2"
  run /usr/bin/env -i \
    HOME="$HOME" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    RESOLUTION_SENTINEL="$sentinel" \
    /bin/bash --noprofile --norc -c '
      dirname() {
        : >"$RESOLUTION_SENTINEL"
        /usr/bin/dirname "$@"
      }
      cd() {
        : >"$RESOLUTION_SENTINEL"
        builtin cd "$@"
      }
      pwd() {
        : >"$RESOLUTION_SENTINEL"
        builtin pwd "$@"
      }
      export -f dirname cd pwd
      exec /bin/bash --noprofile --norc "$1"
    ' _ "$target"
}

prepare_packaged_entrypoint_bundle() {
  local release name variable tree_sha commit
  commit=0123456789012345678901234567890123456789
  HOME="$(/bin/realpath "$HOME")"
  export HOME
  export VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
  release="$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-hostile"
  mkdir -p "$release/config" "$release/lib"
  cp -R "$PROJECT_ROOT/config/." "$release/config/"
  cp -R "$PROJECT_ROOT/lib/." "$release/lib/"
  for name in install verify doctor uninstall; do
    case "$name" in
      install) variable=VIBE_MAC_INSTALL_BUILD_COMMIT ;;
      verify) variable=VIBE_MAC_VERIFY_BUILD_COMMIT ;;
      doctor) variable=VIBE_MAC_DOCTOR_BUILD_COMMIT ;;
      uninstall) variable=VIBE_MAC_UNINSTALL_BUILD_COMMIT ;;
    esac
    /usr/bin/sed \
      "s|$variable='\$Format:%H\$'|$variable='$commit'|" \
      "$PROJECT_ROOT/$name.sh" >"$release/$name.sh"
    chmod 0700 "$release/$name.sh"
  done
  tree_sha="$(/bin/bash -c '
    source "$1/lib/util.sh"
    release_tree_sha256 "$2"
  ' _ "$PROJECT_ROOT" "$release")"
  printf '%s\n' \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$release/.bundle-sha256"
  printf '%s\n' "$tree_sha" >"$release/.bundle-tree-sha256"
  ln -s releases/0.1.0-hostile "$VIBE_MAC_RUNTIME_ROOT/current"
  printf '%s\n' '# tamper before source' >>"$release/lib/util.sh"
  PACKAGED_ENTRYPOINT_RELEASE="$release"
}

@test "четыре entrypoint не исполняют hostile dirname cd pwd до marker gate" {
  local name target sentinel
  for name in install verify doctor uninstall; do
    target="$(copy_entrypoint_with_invalid_release_marker "$name")"

    sentinel="$TEST_ROOT/$name-path-sentinel"
    run /usr/bin/env -i \
      HOME="$HOME" \
      PATH="$HOSTILE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      RESOLUTION_SENTINEL="$sentinel" \
      /bin/bash --noprofile --norc "$target"
    [ "$status" -eq 2 ]
    assert_path_absent "$sentinel"

    sentinel="$TEST_ROOT/$name-function-sentinel"
    run_with_imported_resolution_functions "$target" "$sentinel"
    [ "$status" -eq 2 ]
    assert_path_absent "$sentinel"
  done
}

@test "четыре packaged entrypoint не исполняют hostile resolution до integrity exit" {
  local name target sentinel
  prepare_packaged_entrypoint_bundle
  for name in install verify doctor uninstall; do
    target="$PACKAGED_ENTRYPOINT_RELEASE/$name.sh"

    sentinel="$TEST_ROOT/$name-packaged-path-sentinel"
    run /usr/bin/env -i \
      HOME="$HOME" \
      PATH="$HOSTILE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      RESOLUTION_SENTINEL="$sentinel" \
      /bin/bash --noprofile --norc "$target"
    [ "$status" -eq 2 ]
    assert_path_absent "$sentinel"

    sentinel="$TEST_ROOT/$name-packaged-function-sentinel"
    run_with_imported_resolution_functions "$target" "$sentinel"
    [ "$status" -eq 2 ]
    assert_path_absent "$sentinel"
  done
}

@test "все step entrypoint вычисляют root без hostile dirname cd pwd" {
  local source_step target sentinel
  for source_step in "$PROJECT_ROOT"/steps/*.sh; do
    target="$STEP_FIXTURE_ROOT/steps/${source_step##*/}"
    cp "$source_step" "$target"
    chmod 0700 "$target"

    sentinel="$TEST_ROOT/${source_step##*/}-path-sentinel"
    run /usr/bin/env -i \
      HOME="$HOME" \
      PATH="$HOSTILE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      RESOLUTION_SENTINEL="$sentinel" \
      /bin/bash --noprofile --norc "$target" plan
    [ "$status" -ne 0 ]
    assert_path_absent "$sentinel"

    sentinel="$TEST_ROOT/${source_step##*/}-function-sentinel"
    run_with_imported_resolution_functions "$target" "$sentinel"
    [ "$status" -ne 0 ]
    assert_path_absent "$sentinel"
  done
}
