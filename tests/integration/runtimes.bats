#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  make_fake_command mise '
    printf "mise:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    case "${1:-}" in
      install)
        : >"$TEST_ROOT/mise-installed"
        ;;
      use)
        mkdir -p "$HOME/.config/mise"
        printf "%s\n" generated >"$HOME/.config/mise/config.toml"
        ;;
      where)
        [ -f "$TEST_ROOT/mise-installed" ]
        ;;
      exec)
        case "${4:-}" in
          node) printf "%s\n" "v24.18.1" ;;
          python) printf "%s\n" "Python 3.12.13" ;;
          *) exit 2 ;;
        esac
        ;;
      --version)
        printf "%s\n" "mise 2026.8.0"
        ;;
    esac
  '
  make_fake_command uv 'printf "%s\n" "uv 0.12.1"'
}

@test "runtime step ставит exact Node и Python pins" {
  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "mise:install node@24.18.1 python@3.12.13"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "mise:use --global --pin node@24.18.1 python@3.12.13"
}

@test "существующий global mise config остаётся byte-for-byte" {
  mkdir -p "$HOME/.config/mise"
  printf '%s\n' 'user = "keep"' >"$HOME/.config/mise/config.toml"
  before="$(shasum -a 256 "$HOME/.config/mise/config.toml" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 0 ]
  after="$(shasum -a 256 "$HOME/.config/mise/config.toml" | awk '{print $1}')"
  [ "$before" = "$after" ]
  ! grep -F "mise:use --global" "$VIBE_MAC_EVENT_LOG"
}

@test "runtime step фиксирует ownership и созданный mise global config" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" -extract runtimes.node raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version":"24.18.1"'* ]]
  [[ "$output" == *'"owned":true'* ]]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.mise-global raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path":".config/mise/config.toml"'* ]]
  [[ "$output" == *'"owned":true'* ]]
}
