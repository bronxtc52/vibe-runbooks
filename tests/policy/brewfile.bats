#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
}

@test "основной Brewfile содержит точный обязательный набор" {
  expected="$(printf '%s\n' \
    'brew "git"' \
    'brew "gh"' \
    'brew "starship"' \
    'brew "ripgrep"' \
    'brew "fd"' \
    'brew "fzf"' \
    'brew "bat"' \
    'brew "eza"' \
    'brew "jq"' \
    'brew "tree"' \
    'brew "zoxide"' \
    'brew "mise"' \
    'brew "uv"' \
    'cask "ghostty"' \
    'cask "font-jetbrains-mono-nerd-font"' \
    'cask "claude-code"' \
    'cask "codex"' \
    'cask "cursor"' \
    'cask "cursor-cli"')"

  run /bin/bash -c \
    'grep -E "^(brew|cask) " "$PROJECT_ROOT/Brewfile"'

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "extras изолированы в отдельном точном Brewfile" {
  expected="$(printf '%s\n' \
    'cask "zed"' \
    'cask "raycast"' \
    'cask "visual-studio-code"')"

  run /bin/bash -c \
    'grep -E "^(brew|cask) " "$PROJECT_ROOT/Brewfile.extras"'

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "Brewfiles не содержат запрещённый стек" {
  run rg -n -i \
    'xcode|flutter|dart|cocoapods|android|openjdk|java|kotlin|intellij|webstorm|react-native|unity|ruby|golang|rust|docker|nvm|pyenv|conda|bun' \
    "$PROJECT_ROOT/Brewfile" "$PROJECT_ROOT/Brewfile.extras"

  [ "$status" -eq 1 ]
}
