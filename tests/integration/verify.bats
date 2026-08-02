#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_VERIFY_RESULTS="1 1 1 1 1 1 1 1 1 1 1 1"
}

@test "verify печатает 12 из 12 и остаётся read-only" {
  before="$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)"

  run /bin/bash "$PROJECT_ROOT/verify.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^\[')" -eq 12 ]
  after="$(find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  assert_no_events
}

@test "один красный probe даёт exit 1 и ровно одну repair-команду" {
  export VIBE_MAC_TEST_VERIFY_RESULTS="1 1 1 1 1 1 1 0 1 1 1 1"

  run /bin/bash "$PROJECT_ROOT/verify.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"11 из 12 готово"* ]]
  [[ "$output" == *"[Ошибка] Node.js"* ]]
  [ "$(printf '%s\n' "$output" |
    grep -Fc "/bin/bash \"$HOME/.vibe-mac/current/install.sh\"")" -eq 1 ]
}

@test "невалидный test result делает verify fail-closed с exit 2" {
  export VIBE_MAC_TEST_VERIFY_RESULTS="1 1 broken"

  run /bin/bash "$PROJECT_ROOT/verify.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"Некорректные test probes"* ]]
}

make_verify_command() {
  local name body
  name="$1"
  body="$2"
  make_fake_command "$name" "$body"
}

setup_real_verify_fixture() {
  unset VIBE_MAC_TEST_VERIFY_RESULTS
  export VIBE_MAC_TEST_CLT=installed
  export VIBE_MAC_TEST_HOMEBREW=installed
  export VIBE_MAC_TEST_AI_READY=1
  export VIBE_MAC_TEST_GHOSTTY_APP="$TEST_ROOT/Ghostty.app"
  export VIBE_MAC_TEST_FONT_DIR="$HOME/Library/Fonts"
  mkdir -p \
    "$VIBE_MAC_TEST_GHOSTTY_APP" \
    "$VIBE_MAC_TEST_FONT_DIR" \
    "$HOME/.oh-my-zsh" \
    "$HOME/.config/vibe-mac" \
    "$HOME/Library/Application Support/com.mitchellh.ghostty" \
    "$HOME/dev/hello-vibe"
  : >"$VIBE_MAC_TEST_FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf"
  : >"$HOME/.config/vibe-mac/aliases.zsh"
  : >"$HOME/.config/starship.toml"
  printf '%s\n' \
    '# >>> vibe-mac managed:zprofile >>>' \
    'eval "$(mise activate zsh --shims)"' \
    '# <<< vibe-mac managed:zprofile <<<' >"$HOME/.zprofile"
  printf '%s\n' \
    '# >>> vibe-mac managed:zshrc >>>' \
    'eval "$(mise activate zsh)"' \
    '# <<< vibe-mac managed:zshrc <<<' >"$HOME/.zshrc"
  printf '%s\n' \
    '# >>> vibe-mac managed:ghostty >>>' \
    'font-family = JetBrainsMono Nerd Font' \
    '# <<< vibe-mac managed:ghostty <<<' \
    >"$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  cp "$PROJECT_ROOT/config/AGENTS.md" "$HOME/dev/hello-vibe/AGENTS.md"
  cp "$PROJECT_ROOT/config/CLAUDE.md" "$HOME/dev/hello-vibe/CLAUDE.md"
  cp "$PROJECT_ROOT/config/mise.toml" "$HOME/dev/hello-vibe/.mise.toml"
  : >"$HOME/dev/hello-vibe/index.html"
  printf '%s\n' \
    'можно менять только `index.html`' \
    'не публикуй' >"$HOME/dev/hello-vibe/FIRST-PROMPT.md"
  /usr/bin/git -C "$HOME/dev/hello-vibe" init -q -b feat/first-page

  make_verify_command git 'exec /usr/bin/git "$@"'
  make_verify_command gh 'exit 0'
  for command_name in rg fd fzf bat eza jq tree zoxide; do
    make_verify_command "$command_name" 'exit 0'
  done
  make_verify_command mise '
    case "${1:-}" in
      --version) printf "%s\n" "mise 2026.8.0" ;;
      -C)
        case "${5:-}" in
          node) printf "%s\n" "v24.18.1" ;;
          python) printf "%s\n" "Python 3.12.13" ;;
          *) exit 2 ;;
        esac
        ;;
      *) exit 2 ;;
    esac
  '
  make_verify_command uv 'printf "%s\n" "uv 0.12.1"'
  PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
}

@test "real probe wiring даёт 12/12 на полном synthetic fixture" {
  setup_real_verify_fixture

  run /bin/bash "$PROJECT_ROOT/verify.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"12 из 12 готово"* ]]
}

@test "один missing CLI красит только агрегат CLI-набор" {
  setup_real_verify_fixture
  /bin/unlink "$TEST_ROOT/fake-bin/fd"

  run /bin/bash "$PROJECT_ROOT/verify.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[Ошибка] CLI-набор"* ]]
  [[ "$output" == *"11 из 12 готово"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^\[Ошибка\]')" -eq 1 ]
}
