#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_HOMEBREW_INSTALLER="$TEST_ROOT/homebrew-install.sh"
  /bin/mkdir -p "$TEST_ROOT/hostile-bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' \
    >"$TEST_ROOT/hostile-bin/tee"
  /bin/chmod +x "$TEST_ROOT/hostile-bin/tee"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'set -eu'
    printf '%s\n' '{'
    printf '%s\n' \
      '  printf "bash_env=%s\n" "${BASH_ENV-unset}"' \
      '  printf "env=%s\n" "${ENV-unset}"' \
      '  printf "askpass=%s\n" "${SUDO_ASKPASS-unset}"' \
      '  printf "api=%s\n" "${HOMEBREW_API_DOMAIN-unset}"' \
      '  printf "bottle=%s\n" "${HOMEBREW_BOTTLE_DOMAIN-unset}"' \
      '  printf "brew_remote=%s\n" "${HOMEBREW_BREW_GIT_REMOTE-unset}"' \
      '  printf "core_remote=%s\n" "${HOMEBREW_CORE_GIT_REMOTE-unset}"' \
      '  printf "git_global=%s\n" "${GIT_CONFIG_GLOBAL-unset}"' \
      '  printf "git_nosystem=%s\n" "${GIT_CONFIG_NOSYSTEM-unset}"' \
      '  printf "curl_home=%s\n" "${CURL_HOME-unset}"' \
      '  printf "xdg_config=%s\n" "${XDG_CONFIG_HOME-unset}"' \
      '  printf "git_seen=%s\n" "$(/usr/bin/git config --global --get test.hostile 2>/dev/null || true)"' \
      '  printf "path=%s\n" "$PATH"' \
      '  printf "tee=%s\n" "$(command -v tee)"' \
      '} >"$VIBE_MAC_TEST_RESULT_DIR/homebrew-installer-env.log"'
    printf '%s\n' '/usr/bin/curl --silent --show-error "file://$VIBE_MAC_TEST_RESULT_DIR/curl-payload" >/dev/null'
  } >"$VIBE_MAC_TEST_HOMEBREW_INSTALLER"
  /bin/chmod 0700 "$VIBE_MAC_TEST_HOMEBREW_INSTALLER"
}

@test "pinned Homebrew installer получает только allowlisted environment" {
  printf '%s\n' '[test]' 'hostile = yes' >"$HOME/.gitconfig"
  printf 'payload' >"$HOME/curl-payload"
  printf 'output = "%s"\n' "$HOME/curlrc-fired" >"$HOME/.curlrc"
  export PATH="$TEST_ROOT/hostile-bin:$PATH"
  export BASH_ENV="$TEST_ROOT/nonexistent-bash-env"
  export ENV="$TEST_ROOT/hostile-env"
  export SUDO_ASKPASS="$TEST_ROOT/hostile-askpass"
  export HOMEBREW_API_DOMAIN="https://attacker.invalid/api"
  export HOMEBREW_BOTTLE_DOMAIN="https://attacker.invalid/bottles"
  export HOMEBREW_BREW_GIT_REMOTE="https://attacker.invalid/brew.git"
  export HOMEBREW_CORE_GIT_REMOTE="https://attacker.invalid/core.git"

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" \
    test-run-clean-installer

  [ "$status" -eq 0 ]
  assert_file_contains "$HOME/homebrew-installer-env.log" "bash_env=unset"
  assert_file_contains "$HOME/homebrew-installer-env.log" "env=unset"
  assert_file_contains "$HOME/homebrew-installer-env.log" "askpass=unset"
  assert_file_contains "$HOME/homebrew-installer-env.log" "api=unset"
  assert_file_contains "$HOME/homebrew-installer-env.log" "bottle=unset"
  assert_file_contains "$HOME/homebrew-installer-env.log" "brew_remote=unset"
  assert_file_contains "$HOME/homebrew-installer-env.log" "core_remote=unset"
  assert_file_contains "$HOME/homebrew-installer-env.log" "git_global=/dev/null"
  assert_file_contains "$HOME/homebrew-installer-env.log" "git_nosystem=1"
  assert_file_contains "$HOME/homebrew-installer-env.log" "curl_home=/var/empty"
  assert_file_contains "$HOME/homebrew-installer-env.log" "xdg_config=/var/empty"
  assert_file_contains "$HOME/homebrew-installer-env.log" "git_seen="
  assert_path_absent "$HOME/curlrc-fired"
  assert_file_contains "$HOME/homebrew-installer-env.log" \
    "path=/usr/bin:/bin:/usr/sbin:/sbin"
  assert_file_contains "$HOME/homebrew-installer-env.log" "tee=/usr/bin/tee"
  run /usr/bin/grep -Fq "attacker.invalid" \
    "$HOME/homebrew-installer-env.log"
  [ "$status" -ne 0 ]
}

@test "test action недоступен вне test mode" {
  run env -u VIBE_MAC_TEST_MODE \
    HOME="$HOME" \
    VIBE_MAC_TEST_HOMEBREW_INSTALLER="$VIBE_MAC_TEST_HOMEBREW_INSTALLER" \
    /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" \
    test-run-clean-installer

  [ "$status" -eq 2 ]
}

@test "Homebrew readiness probe очищает hostile environment и PATH" {
  export VIBE_MAC_TEST_HOMEBREW=installed
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"
  /bin/mkdir -p "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin"
  make_fake_command brew '
    printf "probe:%s|bash_env=%s|env=%s|api=%s|remote=%s|rubyopt=%s|git_global=%s|git_nosystem=%s|curl_home=%s|xdg=%s|path=%s\n" \
      "$*" "${BASH_ENV-unset}" "${ENV-unset}" \
      "${HOMEBREW_API_DOMAIN-unset}" \
      "${HOMEBREW_BREW_GIT_REMOTE-unset}" \
      "${RUBYOPT-unset}" "${GIT_CONFIG_GLOBAL-unset}" \
      "${GIT_CONFIG_NOSYSTEM-unset}" "${CURL_HOME-unset}" \
      "${XDG_CONFIG_HOME-unset}" "$PATH" >>"$VIBE_MAC_EVENT_LOG"
    case "${1:-}" in
      --prefix) printf "%s\n" "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" ;;
      --version) printf "%s\n" "Homebrew 5.0" ;;
      *) exit 2 ;;
    esac
  '
  /bin/cp "$TEST_ROOT/fake-bin/brew" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  export PATH="$TEST_ROOT/hostile-bin:$PATH"
  export BASH_ENV="$TEST_ROOT/hostile-bash-env"
  export ENV="$TEST_ROOT/hostile-env"
  export HOMEBREW_API_DOMAIN="https://attacker.invalid/api"
  export HOMEBREW_BREW_GIT_REMOTE="https://attacker.invalid/brew.git"
  export RUBYOPT="-r$TEST_ROOT/hostile.rb"

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" verify

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "bash_env=unset|env=unset|api=unset|remote=unset|rubyopt=unset|git_global=/dev/null|git_nosystem=1|curl_home=/var/empty|xdg=/var/empty"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "path=$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run /usr/bin/grep -Fq "attacker.invalid" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "arm64 sudo effects с точными путями показаны до подтверждения" {
  export VIBE_MAC_TEST_ARCH=arm64
  export VIBE_MAC_TEST_HOMEBREW_MARKER="$TEST_ROOT/homebrew-installed"
  export VIBE_MAC_TEST_RESPONSE=нет

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"Создать /opt/homebrew и каталоги Homebrew только внутри него."* ]]
  [[ "$output" == *"Исправить владельца, группу и права у /opt/homebrew"* ]]
  [[ "$output" == *"/etc/paths.d/homebrew; внутри будет только /opt/homebrew/bin."* ]]
  effects_line="$(printf '%s\n' "$output" |
    /usr/bin/grep -nF "Создать /opt/homebrew" | /usr/bin/head -n 1 |
    /usr/bin/cut -d: -f1)"
  paths_line="$(printf '%s\n' "$output" |
    /usr/bin/grep -nF "/etc/paths.d/homebrew" | /usr/bin/head -n 1 |
    /usr/bin/cut -d: -f1)"
  confirm_line="$(printf '%s\n' "$output" |
    /usr/bin/grep -nF "Разрешаешь тестовую" | /usr/bin/head -n 1 |
    /usr/bin/cut -d: -f1)"
  [ "$effects_line" -lt "$confirm_line" ]
  [ "$paths_line" -lt "$confirm_line" ]
  assert_path_absent "$VIBE_MAC_TEST_HOMEBREW_MARKER"
  assert_no_events
}

@test "Intel sudo effects ограничены Homebrew-путями в /usr/local" {
  export VIBE_MAC_TEST_ARCH=x86_64
  export VIBE_MAC_TEST_HOMEBREW_MARKER="$TEST_ROOT/homebrew-installed"
  export VIBE_MAC_TEST_RESPONSE=нет

  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" apply

  [ "$status" -eq 1 ]
  [[ "$output" == *"Создать /usr/local/Homebrew и каталоги Homebrew внутри /usr/local."* ]]
  [[ "$output" == *"Исправить владельца, группу и права только у каталогов Homebrew внутри /usr/local."* ]]
  [[ "$output" == *"Не менять /etc/paths.d/homebrew"* ]]
  assert_path_absent "$VIBE_MAC_TEST_HOMEBREW_MARKER"
  assert_no_events
}

@test "plan Homebrew объясняет действие без служебного жаргона" {
  run /bin/bash "$PROJECT_ROOT/steps/20-homebrew.sh" plan

  [ "$status" -eq 0 ]
  [[ "$output" == *"официальный установщик Homebrew"* ]]
  [[ "$output" == *"проверю его подлинность"* ]]
  [[ "$output" != *"pinned"* ]]
  [[ "$output" != *"SHA-256"* ]]
  [[ "$output" != *"prefix"* ]]
}
