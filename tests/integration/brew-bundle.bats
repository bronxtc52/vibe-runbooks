#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_BUNDLE_MARKER="$TEST_ROOT/bundle-installed"
  export VIBE_MAC_FAKE_FORMULAE="jq"
  export VIBE_MAC_FAKE_CASKS="cursor"
  export EXTRAS=0

  make_fake_command brew '
    printf "brew:%s|install_upgrade=%s|bundle_upgrade=%s|cleanup=%s|brew_skip=%s|cask_skip=%s\n" \
      "$*" \
      "${HOMEBREW_NO_INSTALL_UPGRADE:-}" \
      "${HOMEBREW_BUNDLE_NO_UPGRADE:-}" \
      "${HOMEBREW_NO_INSTALL_CLEANUP:-}" \
      "${HOMEBREW_BUNDLE_BREW_SKIP:-}" \
      "${HOMEBREW_BUNDLE_CASK_SKIP:-}" >>"$VIBE_MAC_EVENT_LOG"
    case "${1:-}" in
      --prefix)
        printf "%s\n" /opt/homebrew
        ;;
      list)
        if [ "${2:-}" = "--formula" ] && [ "${3:-}" = "--versions" ]; then
          if [ -f "$VIBE_MAC_TEST_BUNDLE_MARKER" ] && [ "${VIBE_MAC_FAKE_CHANGE_DIRECT:-0}" = "1" ]; then
            printf "%s\n" "jq 2.0"
          else
            printf "%s\n" "jq 1.0"
          fi
          if [ -f "$VIBE_MAC_TEST_BUNDLE_MARKER" ] && [ "${VIBE_MAC_FAKE_CHANGE_DEP:-0}" = "1" ]; then
            printf "%s\n" "transitive-dep 2.0"
          elif [ "${VIBE_MAC_FAKE_CHANGE_DEP:-0}" = "1" ]; then
            printf "%s\n" "transitive-dep 1.0"
          fi
        elif [ "${2:-}" = "--cask" ] && [ "${3:-}" = "--versions" ]; then
          printf "%s\n" "cursor 1.0"
        elif [ "${2:-}" = "--formula" ]; then
          case " $VIBE_MAC_FAKE_FORMULAE " in
            *" ${3:-} "*) exit 0 ;;
            *) exit 1 ;;
          esac
        elif [ "${2:-}" = "--cask" ]; then
          case " $VIBE_MAC_FAKE_CASKS " in
            *" ${3:-} "*) exit 0 ;;
            *) exit 1 ;;
          esac
        fi
        ;;
      bundle)
        [ "${2:-}" = "install" ] || exit 2
        : >"$VIBE_MAC_TEST_BUNDLE_MARKER"
        ;;
      --version)
        printf "%s\n" "Homebrew 5.0"
        ;;
    esac
  '
  PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init \
      "$PROJECT_ROOT/state/manifest-template.json" \
      "$VIBE_MAC_MANIFEST_FILE"
  '
}

@test "brew bundle использует no-upgrade/no-cleanup и skip preexisting" {
  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -eq 0 ]
  [ -f "$VIBE_MAC_TEST_BUNDLE_MARKER" ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "bundle install --file=$PROJECT_ROOT/Brewfile --no-upgrade"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "install_upgrade=1"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "bundle_upgrade=1"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "cleanup=1"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew_skip=jq"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "cask_skip=cursor"
  ! grep -E 'brew:(upgrade|cleanup|reinstall|pin)' "$VIBE_MAC_EVENT_LOG"
}

@test "EXTRAS вызывает только отдельный extras manifest" {
  export EXTRAS=1

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "bundle install --file=$PROJECT_ROOT/Brewfile.extras --no-upgrade"
}

@test "изменение прямого preexisting package делает шаг красным" {
  export VIBE_MAC_FAKE_CHANGE_DIRECT=1

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"прямой preexisting package: jq"* ]]
}

@test "изменение транзитивной зависимости проходит только с явным warning" {
  export VIBE_MAC_FAKE_CHANGE_DEP=1

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"formula snapshot изменился"* ]]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.dependency_delta raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"transitive-dep"* ]]
  [[ "$output" == *"1.0"* ]]
  [[ "$output" == *"2.0"* ]]
}

@test "manifest различает preexisting и owned packages" {
  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.jq raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"preexisting":true'* ]]
  [[ "$output" == *'"owned":false'* ]]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.ripgrep raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"preexisting":false'* ]]
  [[ "$output" == *'"owned":true'* ]]
}

@test "plan шага 30 не вызывает Homebrew" {
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" plan

  [ "$status" -eq 0 ]
  assert_no_events
}
