#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_TEST_BUNDLE_MARKER="$TEST_ROOT/bundle-installed"
  export VIBE_MAC_FAKE_FORMULAE="jq"
  export VIBE_MAC_FAKE_CASKS="cursor"
  export VIBE_MAC_FAKE_NEW_FORMULAE="ripgrep"
  export VIBE_MAC_FAKE_NEW_CASKS=""
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"
  export VIBE_MAC_TEST_APPLICATIONS_ROOT="$TEST_ROOT/Applications"
  export EXTRAS=0

  mkdir -p \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin" \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT"

  make_fake_command brew '
    disk_config=unset
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      config_file="$XDG_CONFIG_HOME/homebrew/brew.env"
    else
      config_file="$HOME/.homebrew/brew.env"
    fi
    if [ -f "$config_file" ]; then
      disk_config="$(/bin/cat "$config_file")"
    fi
    printf "brew:%s|install_upgrade=%s|bundle_upgrade=%s|cleanup=%s|brew_skip=%s|cask_skip=%s\n" \
      "$*" \
      "${HOMEBREW_NO_INSTALL_UPGRADE:-}" \
      "${HOMEBREW_BUNDLE_NO_UPGRADE:-}" \
      "${HOMEBREW_NO_INSTALL_CLEANUP:-}" \
      "${HOMEBREW_BUNDLE_BREW_SKIP:-}" \
      "${HOMEBREW_BUNDLE_CASK_SKIP:-}" >>"$VIBE_MAC_EVENT_LOG"
    printf "brew-env:bash_env=%s|env=%s|askpass=%s|api=%s|bottle=%s|brew_remote=%s|core_remote=%s|git_global=%s|git_nosystem=%s|curl_home=%s|xdg=%s|disk_config=%s|path=%s\n" \
      "${BASH_ENV-unset}" \
      "${ENV-unset}" \
      "${SUDO_ASKPASS-unset}" \
      "${HOMEBREW_API_DOMAIN-unset}" \
      "${HOMEBREW_BOTTLE_DOMAIN-unset}" \
      "${HOMEBREW_BREW_GIT_REMOTE-unset}" \
      "${HOMEBREW_CORE_GIT_REMOTE-unset}" \
      "${GIT_CONFIG_GLOBAL-unset}" \
      "${GIT_CONFIG_NOSYSTEM-unset}" \
      "${CURL_HOME-unset}" \
      "${XDG_CONFIG_HOME-unset}" \
      "$disk_config" \
      "$PATH" >>"$VIBE_MAC_EVENT_LOG"
    marker_present=0
    if [ -n "${VIBE_MAC_TEST_BUNDLE_MARKER:-}" ] &&
      [ -f "$VIBE_MAC_TEST_BUNDLE_MARKER" ]; then
      marker_present=1
    fi
    case "${1:-}" in
      --prefix)
        printf "%s\n" /opt/homebrew
        ;;
      list)
        if [ "${2:-}" = "--formula" ] && [ "${3:-}" = "--versions" ]; then
          if [ "$marker_present" = "1" ] && [ "${VIBE_MAC_FAKE_CHANGE_DIRECT:-0}" = "1" ]; then
            printf "%s\n" "jq 2.0"
          else
            printf "%s\n" "jq 1.0"
          fi
          case " $VIBE_MAC_FAKE_FORMULAE " in
            *" ripgrep "*) printf "%s\n" "ripgrep 14.1.0" ;;
          esac
          if [ "$marker_present" = "1" ]; then
            case " $VIBE_MAC_FAKE_NEW_FORMULAE " in
              *" ripgrep "*) printf "%s\n" "ripgrep 14.1.0" ;;
            esac
          fi
          if [ "$marker_present" = "1" ] && [ "${VIBE_MAC_FAKE_CHANGE_DEP:-0}" = "1" ]; then
            printf "%s\n" "transitive-dep 2.0"
          elif [ "${VIBE_MAC_FAKE_CHANGE_DEP:-0}" = "1" ]; then
            printf "%s\n" "transitive-dep 1.0"
          elif [ "$marker_present" = "1" ] && [ "${VIBE_MAC_FAKE_CHANGE_DEP:-0}" = "control" ]; then
            printf "transitive-dep 2.0\001\n"
          elif [ "${VIBE_MAC_FAKE_CHANGE_DEP:-0}" = "control" ]; then
            printf "transitive-dep 1.0\001\n"
          fi
        elif [ "${2:-}" = "--cask" ] && [ "${3:-}" = "--versions" ]; then
          printf "%s\n" "cursor 1.0"
          if [ "$marker_present" = "1" ]; then
            case " $VIBE_MAC_FAKE_NEW_CASKS " in
              *" ghostty "*) printf "%s\n" "ghostty 1.2.3" ;;
            esac
          fi
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
        [ "${VIBE_MAC_FAKE_BUNDLE_FAIL:-0}" != "1" ] || exit 9
        if [ -n "${VIBE_MAC_TEST_BUNDLE_MARKER:-}" ] &&
          [ "${VIBE_MAC_FAKE_SKIP_MARKER:-0}" != "1" ]; then
          : >"$VIBE_MAC_TEST_BUNDLE_MARKER"
        fi
        ;;
      --version)
        printf "%s\n" "Homebrew 5.0"
        ;;
    esac
  '
  cp \
    "$TEST_ROOT/fake-bin/brew" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/brew"
  PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init \
      "$PROJECT_ROOT/state/manifest-template.json" \
      "$VIBE_MAC_MANIFEST_FILE"
  '
}

make_test_app_bundle() {
  local app executable identifier
  app="$1"
  executable="$2"
  identifier="$3"
  /bin/mkdir -p "$app/Contents/MacOS"
  printf '{"CFBundleExecutable":"%s","CFBundleIdentifier":"%s"}\n' \
    "$executable" "$identifier" >"$app/Contents/Info.plist"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"$app/Contents/MacOS/$executable"
  /bin/chmod 0700 "$app/Contents/MacOS/$executable"
}

make_test_font() {
  local font
  font="$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"
  /bin/mkdir -p "${font%/*}"
  printf '\000\001\000\000' >"$font"
  /bin/dd if=/dev/zero bs=1020 count=1 >>"$font" 2>/dev/null
}

make_test_gui_and_font() {
  make_test_app_bundle \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" Ghostty com.example.Ghostty
  make_test_app_bundle \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app" Cursor com.example.Cursor
  make_test_font
}

prepare_complete_bundle_fixture() {
  unset VIBE_MAC_TEST_BUNDLE_MARKER
  export VIBE_MAC_FAKE_FORMULAE="git gh starship ripgrep fd fzf bat eza jq tree zoxide mise uv"
  export VIBE_MAC_FAKE_CASKS="ghostty font-jetbrains-mono-nerd-font claude-code codex cursor cursor-cli"
  mkdir -p \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app" \
    "$HOME/Library/Fonts"
  make_test_gui_and_font

  command_names="git gh starship rg fd fzf bat eza jq tree zoxide mise uv claude codex cursor cursor-agent"
  for command_name in $command_names; do
    make_fake_command "$command_name" '
      command_name="${0##*/}"
      printf "version:%s:%s\n" "$command_name" "$*" >>"$VIBE_MAC_EVENT_LOG"
      printf "version-env:%s|bash_env=%s|env=%s|node_options=%s|git_config=%s|gh_host=%s|pythonpath=%s|mise_config=%s|path=%s\n" \
        "$command_name" "${BASH_ENV-unset}" "${ENV-unset}" \
        "${NODE_OPTIONS-unset}" "${GIT_CONFIG_GLOBAL-unset}" \
        "${GH_HOST-unset}" "${PYTHONPATH-unset}" \
        "${MISE_CONFIG_FILE-unset}" "$PATH" >>"$VIBE_MAC_EVENT_LOG"
      [ "${VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND:-}" != "$command_name" ] || exit 23
      printf "%s\n" "$command_name 1.0"
    '
    cp \
      "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
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

@test "brew запускается в allowlisted env без source и remote overrides" {
  /bin/mkdir -p "$HOME/.homebrew"
  printf '%s\n' 'HOMEBREW_API_DOMAIN=https://attacker.invalid/from-disk' \
    >"$HOME/.homebrew/brew.env"
  export BASH_ENV="$TEST_ROOT/hostile-bash-env"
  export ENV="$TEST_ROOT/hostile-env"
  export SUDO_ASKPASS="$TEST_ROOT/hostile-askpass"
  export HOMEBREW_API_DOMAIN="https://attacker.invalid/api"
  export HOMEBREW_BOTTLE_DOMAIN="https://attacker.invalid/bottles"
  export HOMEBREW_BREW_GIT_REMOTE="https://attacker.invalid/brew.git"
  export HOMEBREW_CORE_GIT_REMOTE="https://attacker.invalid/core.git"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "brew-env:bash_env=unset|env=unset|askpass=unset|api=unset|bottle=unset|brew_remote=unset|core_remote=unset"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "git_global=/dev/null|git_nosystem=1|curl_home=/var/empty|xdg=/var/empty"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "disk_config=unset"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "path=$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run /usr/bin/grep -Fq "attacker.invalid" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
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
  [[ "$output" == *"Homebrew изменил служебный компонент: transitive-dep."* ]]
  [[ "$output" == *"Было: transitive-dep 1.0"* ]]
  [[ "$output" == *"Стало: transitive-dep 2.0"* ]]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.dependency_delta json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"transitive-dep"* ]]
  [[ "$output" == *"1.0"* ]]
  [[ "$output" == *"2.0"* ]]
}

@test "готовый повторный apply сохраняет историю packages и dependency delta" {
  export VIBE_MAC_FAKE_CHANGE_DEP=1

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.ripgrep.version_before raw -- \
    "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.dependency_delta json -o - -- \
    "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  dependency_history="$output"
  [[ "$dependency_history" == *"transitive-dep"* ]]

  export VIBE_MAC_FAKE_CHANGE_DEP=0
  : >"$VIBE_MAC_EVENT_LOG"
  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply
  [ "$status" -eq 0 ]
  run /usr/bin/grep -Fq "bundle install" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.ripgrep.version_before raw -- \
    "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.dependency_delta json -o - -- \
    "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "$dependency_history" ]
}

@test "control character в dependency delta останавливает apply" {
  export VIBE_MAC_FAKE_CHANGE_DEP=control

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"неожиданные символы"* ]]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.dependency_delta json -o - -- \
    "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "manifest различает preexisting и owned packages" {
  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.jq json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"preexisting":true'* ]]
  [[ "$output" == *'"owned":false'* ]]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.ripgrep json -o - -- "$VIBE_MAC_MANIFEST_FILE"
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

@test "уже готовый bundle только фиксируется в manifest" {
  : >"$VIBE_MAC_TEST_BUNDLE_MARKER"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -eq 0 ]
  ! grep -F "bundle install" "$VIBE_MAC_EVENT_LOG"
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.jq json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"preexisting":true'* ]]
  [[ "$output" == *'"owned":false'* ]]
}

@test "bare PATH CLI не даёт skip, exact GUI app и font сохраняются" {
  export VIBE_MAC_FAKE_CASKS=""
  mkdir -p \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app" \
    "$HOME/Library/Fonts"
  make_test_gui_and_font
  for command_name in rg claude codex cursor-agent; do
    make_fake_command "$command_name" 'exit 0'
  done

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -eq 0 ]
  bundle_event="$(grep -F 'brew:bundle install' "$VIBE_MAC_EVENT_LOG")"
  brew_skip="${bundle_event#*|brew_skip=}"
  brew_skip="${brew_skip%%|cask_skip=*}"
  cask_skip="${bundle_event##*|cask_skip=}"
  [[ " $brew_skip " == *' jq '* ]]
  [[ " $brew_skip " != *' ripgrep '* ]]
  [[ " $cask_skip " == *' ghostty '* ]]
  [[ " $cask_skip " == *' font-jetbrains-mono-nerd-font '* ]]
  [[ " $cask_skip " == *' cursor '* ]]
  [[ " $cask_skip " != *' claude-code '* ]]
  [[ " $cask_skip " != *' codex '* ]]
  [[ " $cask_skip " != *' cursor-cli '* ]]
}

@test "bundle verify требует required CLI из exact Homebrew prefix" {
  unset VIBE_MAC_TEST_BUNDLE_MARKER
  export VIBE_MAC_FAKE_FORMULAE="git gh starship ripgrep fd fzf bat eza jq tree zoxide mise uv"
  export VIBE_MAC_FAKE_CASKS="ghostty font-jetbrains-mono-nerd-font claude-code codex cursor cursor-cli"
  mkdir -p \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app" \
    "$HOME/Library/Fonts"
  make_test_gui_and_font

  command_names="git gh starship rg fd fzf bat eza jq tree zoxide mise uv claude codex cursor cursor-agent"
  for command_name in $command_names; do
    make_fake_command "$command_name" \
      'printf "%s\n" "${0##*/} 1.0"'
  done

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify
  [ "$status" -ne 0 ]

  for command_name in $command_names; do
    cp \
      "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify
  [ "$status" -eq 0 ]
}

@test "bundle verify отклоняет broken CLI из exact Homebrew prefix" {
  prepare_complete_bundle_fixture
  export VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND=rg
  make_fake_command rg '
    printf "%s\n" "trojan:rg:$*" >>"$VIBE_MAC_EVENT_LOG"
    printf "%s\n" "rg 99.0"
  '
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -ne 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "version:rg:--version"
  run /usr/bin/grep -Fq "trojan:rg:" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "bundle verify не запускает внешний symlink из Homebrew prefix" {
  prepare_complete_bundle_fixture
  make_fake_command outside-rg '
    printf "%s\n" "outside:rg:$*" >>"$VIBE_MAC_EVENT_LOG"
    exit 0
  '
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/rg"
  /bin/ln -s \
    "$TEST_ROOT/fake-bin/outside-rg" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/rg"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 2 ]
  run /usr/bin/grep -Fq "outside:rg:" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "bundle verify считает dangling symlink отсутствующим CLI" {
  prepare_complete_bundle_fixture
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/rg"
  /bin/ln -s \
    "$TEST_ROOT/missing-rg" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/rg"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 1 ]
}

@test "bundle verify принимает внутренний Cellar symlink" {
  prepare_complete_bundle_fixture
  cellar_bin="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/ripgrep/14.1.0/bin"
  /bin/mkdir -p "$cellar_bin"
  /bin/mv \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/rg" \
    "$cellar_bin/rg"
  /bin/ln -s \
    "../Cellar/ripgrep/14.1.0/bin/rg" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/rg"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "version:rg:--version"
}

@test "bundle verify отклоняет пустые Ghostty и Cursor app bundles" {
  prepare_complete_bundle_fixture
  /usr/bin/find \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app/Contents" \
    -depth -delete

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify
  [ "$status" -eq 1 ]

  make_test_app_bundle \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" \
    Ghostty com.example.Ghostty
  /usr/bin/find \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app/Contents" \
    -depth -delete

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify
  [ "$status" -eq 1 ]
}

@test "bundle verify отклоняет zero-byte и magic-only Nerd Font" {
  prepare_complete_bundle_fixture
  font="$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"
  : >"$font"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify
  [ "$status" -eq 1 ]

  printf '\000\001\000\000' >"$font"
  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify
  [ "$status" -eq 1 ]
}

@test "bundle verify запускает version probe каждого required CLI" {
  prepare_complete_bundle_fixture
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 0 ]
  for command_name in \
    git gh starship rg fd fzf bat eza jq tree zoxide mise uv \
    claude codex cursor-agent; do
    assert_file_contains "$VIBE_MAC_EVENT_LOG" \
      "version:$command_name:--version"
  done
}

@test "bundle version probes очищают hostile runtime и config environment" {
  prepare_complete_bundle_fixture
  export PATH="$TEST_ROOT/hostile-bin:$PATH"
  export BASH_ENV="$TEST_ROOT/hostile-bash-env"
  export ENV="$TEST_ROOT/hostile-env"
  export NODE_OPTIONS="--require=$TEST_ROOT/hostile-node.cjs"
  export GIT_CONFIG_GLOBAL="$TEST_ROOT/hostile.gitconfig"
  export GH_HOST=attacker.invalid
  export PYTHONPATH="$TEST_ROOT/hostile-python"
  export MISE_CONFIG_FILE="$TEST_ROOT/hostile-mise.toml"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 0 ]
  for command_name in \
    git gh starship rg fd fzf bat eza jq tree zoxide mise uv \
    claude codex cursor-agent; do
    assert_file_contains "$VIBE_MAC_EVENT_LOG" \
      "version-env:$command_name|bash_env=unset|env=unset|node_options=unset|git_config=unset|gh_host=unset|pythonpath=unset|mise_config=unset|path=$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  done
  run /usr/bin/grep -Fq "attacker.invalid" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "bundle version probes используют no-write env и не вызывают auxiliary cursor" {
  prepare_complete_bundle_fixture
  export VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND=cursor
  for command_name in \
    git gh starship rg fd fzf bat eza jq tree zoxide mise uv \
    claude codex cursor cursor-agent; do
    make_fake_command "$command_name" '
      command_name="${0##*/}"
      expected_cwd="$(cd /var/empty && /bin/pwd -P)"
      if [ "$HOME" != /var/empty ] ||
        [ "${TMPDIR:-}" != /var/empty ] ||
        [ "$(/bin/pwd -P)" != "$expected_cwd" ] ||
        [ "${DO_NOT_TRACK:-}" != 1 ] ||
        [ "${GH_TELEMETRY:-}" != disabled ] ||
        [ "${HOMEBREW_NO_ANALYTICS:-}" != 1 ] ||
        [ "${HOMEBREW_NO_AUTO_UPDATE:-}" != 1 ] ||
        [ "${HOMEBREW_NO_INSTALL_UPGRADE:-}" != 1 ] ||
        [ "${HOMEBREW_NO_INSTALL_CLEANUP:-}" != 1 ] ||
        [ "${HOMEBREW_NO_ENV_HINTS:-}" != 1 ] ||
        [ "${DISABLE_AUTOUPDATER:-}" != 1 ] ||
        [ "${DISABLE_TELEMETRY:-}" != 1 ] ||
        [ "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" != 1 ] ||
        [ "${MISE_AUTO_INSTALL:-}" != 0 ] ||
        [ "${MISE_EXEC_AUTO_INSTALL:-}" != 0 ] ||
        [ "${MISE_OFFLINE:-}" != 1 ]; then
        printf "tripwire:%s:network-or-write\n" "$command_name" \
          >>"$VIBE_MAC_EVENT_LOG"
        exit 97
      fi
      if [ "${VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND:-}" = "$command_name" ]; then
        printf "auxiliary-executed:%s\n" "$command_name" \
          >>"$VIBE_MAC_EVENT_LOG"
        exit 23
      fi
      printf "safe-version:%s:%s\n" "$command_name" "$*" \
        >>"$VIBE_MAC_EVENT_LOG"
      [ "$*" = --version ]
      printf "%s\n" "$command_name 1.0"
    '
    cp "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 0 ]
  for command_name in \
    git gh starship rg fd fzf bat eza jq tree zoxide mise uv \
    claude codex cursor-agent; do
    assert_file_contains "$VIBE_MAC_EVENT_LOG" \
      "safe-version:$command_name:--version"
  done
  [ "$(grep -c '^tripwire:' "$VIBE_MAC_EVENT_LOG" || true)" -eq 0 ]
  [ "$(grep -c '^auxiliary-executed:cursor$' \
    "$VIBE_MAC_EVENT_LOG" || true)" -eq 0 ]
  [ "$(grep -c '^safe-version:cursor:' \
    "$VIBE_MAC_EVENT_LOG" || true)" -eq 0 ]
}

@test "FULL_VERIFY запускает version probes, а не только проверяет файлы" {
  prepare_complete_bundle_fixture
  : >"$VIBE_MAC_EVENT_LOG"

  run env DRY_RUN=1 VIBE_MAC_FULL_VERIFY=1 \
    /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "version:git:--version"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "version:cursor-agent:--version"
}

@test "verify-receipts проверяет Brewfile receipts без дублирования version probes" {
  prepare_complete_bundle_fixture
  export VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND=rg
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify-receipts

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew:list --formula mise"
  run /usr/bin/grep -Fq "version:" "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "bundle apply остаётся красным после установки при broken required CLI" {
  prepare_complete_bundle_fixture
  export VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND=rg
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -ne 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "brew:bundle install --file=$PROJECT_ROOT/Brewfile --no-upgrade"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "version:rg:--version"
}

@test "exact Homebrew binary без receipt не маскирует незавершённый bundle" {
  unset VIBE_MAC_TEST_BUNDLE_MARKER
  export VIBE_MAC_FAKE_FORMULAE="git gh starship ripgrep fd fzf bat eza jq tree zoxide uv"
  export VIBE_MAC_FAKE_CASKS="ghostty font-jetbrains-mono-nerd-font claude-code codex cursor cursor-cli"
  mkdir -p \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app" \
    "$HOME/Library/Fonts"
  make_test_gui_and_font

  command_names="git gh starship rg fd fzf bat eza jq tree zoxide mise uv claude codex cursor cursor-agent"
  for command_name in $command_names; do
    make_fake_command "$command_name" 'exit 0'
    cp \
      "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply

  [ "$status" -ne 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "brew:bundle install --file=$PROJECT_ROOT/Brewfile --no-upgrade"
}

@test "DRY_RUN bundle verify не вызывает Homebrew или required CLI" {
  unset VIBE_MAC_TEST_BUNDLE_MARKER
  mkdir -p \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app" \
    "$HOME/Library/Fonts"
  make_test_gui_and_font

  command_names="git gh starship rg fd fzf bat eza jq tree zoxide mise uv claude codex cursor cursor-agent"
  for command_name in $command_names; do
    make_recording_command "$command_name" 0
    cp \
      "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  : >"$VIBE_MAC_EVENT_LOG"

  run env DRY_RUN=1 \
    /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 0 ]
  assert_no_events
}

@test "FULL_VERIFY в DRY_RUN требует Homebrew receipts" {
  unset VIBE_MAC_TEST_BUNDLE_MARKER
  export VIBE_MAC_FAKE_FORMULAE="git gh starship ripgrep fd fzf bat eza jq tree zoxide uv"
  export VIBE_MAC_FAKE_CASKS="ghostty font-jetbrains-mono-nerd-font claude-code codex cursor cursor-cli"
  mkdir -p \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Ghostty.app" \
    "$VIBE_MAC_TEST_APPLICATIONS_ROOT/Cursor.app" \
    "$HOME/Library/Fonts"
  make_test_gui_and_font

  command_names="git gh starship rg fd fzf bat eza jq tree zoxide mise uv claude codex cursor cursor-agent"
  for command_name in $command_names; do
    make_fake_command "$command_name" 'exit 0'
    cp \
      "$TEST_ROOT/fake-bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  : >"$VIBE_MAC_EVENT_LOG"

  run env DRY_RUN=1 VIBE_MAC_FULL_VERIFY=1 \
    /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" verify

  [ "$status" -eq 1 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" "brew:list --formula mise"
}

@test "отсутствующий до и после bundle package не получает ownership" {
  export VIBE_MAC_FAKE_NEW_FORMULAE=""
  export VIBE_MAC_FAKE_NEW_CASKS=""

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.ripgrep json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  if [ "$status" -eq 0 ]; then
    [[ "$output" != *'"owned":true'* ]]
  fi

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.casks.ghostty json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  if [ "$status" -eq 0 ]; then
    [[ "$output" != *'"owned":true'* ]]
  fi
}

@test "failed verify после bundle не присваивает ownership последующей ручной установке" {
  export VIBE_MAC_FAKE_NEW_FORMULAE=""
  export VIBE_MAC_FAKE_SKIP_MARKER=1

  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply
  [ "$status" -ne 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.ripgrep json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -ne 0 ]

  export VIBE_MAC_FAKE_FORMULAE="jq ripgrep"
  export VIBE_MAC_FAKE_SKIP_MARKER=0
  : >"$VIBE_MAC_TEST_BUNDLE_MARKER"
  run /bin/bash "$PROJECT_ROOT/steps/30-brew-bundle.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract packages.formulae.ripgrep json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"preexisting":true'* ]]
  [[ "$output" == *'"owned":false'* ]]

  export VIBE_MAC_TEST_UNINSTALL_FORMULAE=ripgrep
  export VIBE_MAC_TEST_UNINSTALL_CASKS=none
  export VIBE_MAC_TEST_RESPONSE=UNINSTALL
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/uninstall.sh" --apply
  [ "$status" -eq 0 ]
  ! grep -F "brew:uninstall ripgrep" "$VIBE_MAC_EVENT_LOG"
}
