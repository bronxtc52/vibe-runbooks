#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  make_fake_command mise '
    config_root=
    if [ "${1:-}" = -C ]; then
      config_root="${2:-}"
      shift 2
    fi
    printf "mise:%s\n" "$*" >>"$VIBE_MAC_EVENT_LOG"
    if [ -f "$TEST_ROOT/check-mise-isolation" ]; then
      expected_global=/dev/null
      if [ "${1:-}" = use ]; then
        expected_global="$HOME/.config/mise/config.toml"
      fi
      if [ "$config_root" != "${MISE_CONFIG_DIR:-}" ] ||
        [ "$config_root" != "${VIBE_MAC_TEST_TRUSTED_CONFIG_DIR:-missing}" ] ||
        [ "${MISE_AUTO_INSTALL:-}" != 0 ] ||
        [ "${MISE_EXEC_AUTO_INSTALL:-}" != 0 ] ||
        { [ "${1:-}" = install ] && [ "${MISE_OFFLINE:-}" != 0 ]; } ||
        { [ "${1:-}" != install ] && [ "${MISE_OFFLINE:-}" != 1 ]; } ||
        [ "${MISE_GLOBAL_CONFIG_FILE:-}" != "$expected_global" ] ||
        [ "${MISE_SYSTEM_CONFIG_FILE:-}" != /dev/null ] ||
        [ "${MISE_DATA_DIR:-}" != "$HOME/.local/share/mise" ] ||
        [ "${MISE_CACHE_DIR:-}" != "$HOME/.cache/mise" ] ||
        [ "${MISE_STATE_DIR:-}" != "$HOME/.local/state/mise" ] ||
        [ "${MISE_TMP_DIR:-}" != "$TMPDIR" ]; then
        printf "%s\n" mise-config-leak >>"$VIBE_MAC_EVENT_LOG"
        : >"$TEST_ROOT/malicious-config-executed"
      fi
    fi
    case "${1:-}" in
      install)
        if [ -f "$TEST_ROOT/mise-install-fail" ]; then
          exit 9
        fi
        for item in "${@:2}"; do
          name="${item%@*}"
          version="${item#*@}"
          mkdir -p "$HOME/.local/share/mise/installs/$name/$version/bin"
          if [ -f "$TEST_ROOT/mise-install-partial" ]; then
            exit 9
          fi
        done
        ;;
      use)
        mkdir -p "$HOME/.config/mise"
        printf "%s\n" generated >"$HOME/.config/mise/config.toml"
        ;;
      where)
        item="${2:-}"
        name="${item%@*}"
        version="${item#*@}"
        root="$HOME/.local/share/mise/installs/$name/$version"
        [ -d "$root" ] && [ ! -L "$root" ] || exit 1
        printf "%s\n" "$root"
        ;;
      exec)
        item="${2:-}"
        name="${item%@*}"
        version="${item#*@}"
        [ -d "$HOME/.local/share/mise/installs/$name/$version" ] || exit 1
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
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"
  export VIBE_MAC_TEST_TRUSTED_CONFIG_DIR="$PROJECT_ROOT/config"
  mkdir -p "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin"
  /bin/cp "$TEST_ROOT/fake-bin/mise" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"
  /bin/cp "$TEST_ROOT/fake-bin/uv" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/uv"
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

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract runtimes.node json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version":"24.18.1"'* ]]
  [[ "$output" == *'"owned":true'* ]]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-node.created" ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-python.created" ]
  [ "$(/usr/bin/stat -f '%Lp' \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-node.created")" = 600 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.mise-global json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path":".config/mise/config.toml"'* ]]
  [[ "$output" == *'"owned":true'* ]]
}

@test "runtime crash до install не присваивает вручную созданные exact runtimes" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_BEFORE_RUNTIME_INSTALL=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 90 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract runtimes.node.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  mkdir -p \
    "$HOME/.local/share/mise/installs/node/24.18.1/bin" \
    "$HOME/.local/share/mise/installs/python/3.12.13/bin"
  export VIBE_MAC_TEST_CRASH_BEFORE_RUNTIME_INSTALL=0

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 0 ]
  for name in node python; do
    run "$VIBE_MAC_PLUTIL_BIN" \
      -extract "runtimes.$name.preexisting" raw -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
    run "$VIBE_MAC_PLUTIL_BIN" \
      -extract "runtimes.$name.owned" raw -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
    [ ! -e "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-$name.created" ]
  done
  [ -d "$HOME/.local/share/mise/installs/node/24.18.1" ]
  [ -d "$HOME/.local/share/mise/installs/python/3.12.13" ]
}

@test "runtime install failure не создаёт owned receipt или proof" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  : >"$TEST_ROOT/mise-install-fail"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 1 ]
  for name in node python; do
    run "$VIBE_MAC_PLUTIL_BIN" \
      -extract "runtimes.$name.owned" raw -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
    [ ! -e "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-$name.created" ]
  done
}

@test "partial runtime install failure остаётся unowned" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  : >"$TEST_ROOT/mise-install-partial"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 1 ]
  [ -d "$HOME/.local/share/mise/installs/node/24.18.1" ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract runtimes.node.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract runtimes.node.preexisting raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  [ ! -e "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-node.created" ]
}

@test "runtime reconcile сохраняет ownership после сбоя перед финальной записью" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_MISE_USE=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply
  [ "$status" -eq 91 ]
  [ -f "$HOME/.config/mise/config.toml" ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/mise-global.created-sha256" ]

  export VIBE_MAC_TEST_CRASH_AFTER_MISE_USE=0
  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" -extract runtimes.node.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  run "$VIBE_MAC_PLUTIL_BIN" -extract runtimes.python.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  run "$VIBE_MAC_PLUTIL_BIN" -extract files.mise-global.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "runtime reconcile не присваивает вручную созданный config после сбоя на absent evidence" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_MISE_GLOBAL_EVIDENCE=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply
  [ "$status" -eq 92 ]
  [ ! -e "$HOME/.config/mise/config.toml" ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/mise-global.absent" ]
  [ ! -e "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/mise-global.created-sha256" ]

  mkdir -p "$HOME/.config/mise"
  printf '%s\n' generated >"$HOME/.config/mise/config.toml"
  export VIBE_MAC_TEST_CRASH_AFTER_MISE_GLOBAL_EVIDENCE=0

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.mise-global.preexisting raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.mise-global.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
}

@test "runtime reconcile не присваивает изменённый config с устаревшим creation proof" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_MISE_USE=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply
  [ "$status" -eq 91 ]
  printf '%s\n' 'user = "changed"' >"$HOME/.config/mise/config.toml"
  export VIBE_MAC_TEST_CRASH_AFTER_MISE_USE=0

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.mise-global.preexisting raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.mise-global.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
}

@test "runtime step игнорирует PATH trojan и запускает exact Homebrew binaries" {
  make_fake_command mise '
    printf "%s\n" "trojan:mise:$*" >>"$VIBE_MAC_EVENT_LOG"
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise" "$@"
  '
  make_fake_command uv '
    printf "%s\n" "trojan:uv:$*" >>"$VIBE_MAC_EVENT_LOG"
    exec "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/uv" "$@"
  '

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 0 ]
  run /usr/bin/grep -Fq 'trojan:' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "runtime resolver блокирует Homebrew executable symlink наружу" {
  outside="$TEST_ROOT/outside-mise"
  /bin/mv "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise" "$outside"
  /bin/ln -s "$outside" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 2 ]
  [ ! -s "$VIBE_MAC_EVENT_LOG" ]
}

@test "runtime resolver считает dangling Homebrew symlink integrity error" {
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"
  /bin/ln -s ../Cellar/mise/missing/bin/mise \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 2 ]
  [ ! -s "$VIBE_MAC_EVENT_LOG" ]
}

@test "runtime resolver принимает canonical symlink внутрь Homebrew Cellar" {
  cellar_mise="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/mise/2026.8.0/bin/mise"
  /bin/mkdir -p "${cellar_mise%/*}"
  /bin/mv "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise" "$cellar_mise"
  /bin/ln -s ../Cellar/mise/2026.8.0/bin/mise \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 0 ]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "mise:install node@24.18.1 python@3.12.13"
}

@test "runtime resolver блокирует непустой Homebrew brew.env" {
  env_file="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/etc/homebrew/brew.env"
  /bin/mkdir -p "${env_file%/*}"
  printf '%s\n' 'HOMEBREW_API_DOMAIN=https://attacker.invalid' >"$env_file"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 2 ]
  [ ! -s "$VIBE_MAC_EVENT_LOG" ]
}

@test "runtime step не передаёт hostile mise XDG backend mirror и config env" {
  make_fake_command mise '
    config_root=
    if [ "${1:-}" = -C ]; then
      config_root="${2:-}"
      shift 2
    fi
    leaked="$(/usr/bin/env | /usr/bin/grep -E "^(MISE_|XDG_)" | \
      /usr/bin/cut -d= -f1 | \
      /usr/bin/grep -Ev "^(MISE_YES|MISE_AUTO_INSTALL|MISE_EXEC_AUTO_INSTALL|MISE_OFFLINE|MISE_CONFIG_DIR|MISE_GLOBAL_CONFIG_FILE|MISE_SYSTEM_CONFIG_FILE|MISE_DATA_DIR|MISE_CACHE_DIR|MISE_STATE_DIR|MISE_TMP_DIR)$" || true)"
    expected_global=/dev/null
    if [ "${1:-}" = use ]; then
      expected_global="$HOME/.config/mise/config.toml"
    fi
    if [ -n "$leaked" ] ||
      [ "$config_root" != "${VIBE_MAC_TEST_TRUSTED_CONFIG_DIR:-missing}" ] ||
      [ "${MISE_AUTO_INSTALL:-}" != 0 ] ||
      [ "${MISE_EXEC_AUTO_INSTALL:-}" != 0 ] ||
      { [ "${1:-}" = install ] && [ "${MISE_OFFLINE:-}" != 0 ]; } ||
      { [ "${1:-}" != install ] && [ "${MISE_OFFLINE:-}" != 1 ]; } ||
      [ "${MISE_CONFIG_DIR:-}" != "$config_root" ] ||
      [ "${MISE_GLOBAL_CONFIG_FILE:-}" != "$expected_global" ] ||
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
    if [ "${MISE_DATA_DIR:-}" = "$TEST_ROOT/attacker-data" ]; then
      mkdir -p "$MISE_DATA_DIR"
      : >"$MISE_DATA_DIR/hostile-write"
    fi
    case "${1:-}" in
      install)
        for item in "${@:2}"; do
          name="${item%@*}"
          version="${item#*@}"
          mkdir -p "$HOME/.local/share/mise/installs/$name/$version/bin"
        done
        ;;
      use)
        mkdir -p "$HOME/.config/mise"
        printf "%s\n" generated >"$HOME/.config/mise/config.toml"
        ;;
      where)
        item="${2:-}"
        name="${item%@*}"
        version="${item#*@}"
        root="$HOME/.local/share/mise/installs/$name/$version"
        [ -d "$root" ] || exit 1
        printf "%s\n" "$root"
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
  /bin/cp "$TEST_ROOT/fake-bin/mise" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"
  export MISE_DATA_DIR="$TEST_ROOT/attacker-data"
  export MISE_CACHE_DIR="$TEST_ROOT/attacker-cache"
  export MISE_CONFIG_DIR="$TEST_ROOT/attacker-config"
  export MISE_GLOBAL_CONFIG_FILE="$TEST_ROOT/attacker-global.toml"
  export XDG_CONFIG_HOME="$TEST_ROOT/attacker-xdg"
  export XDG_DATA_HOME="$TEST_ROOT/attacker-xdg-data"
  export XDG_CACHE_HOME="$TEST_ROOT/attacker-xdg-cache"
  export XDG_STATE_HOME="$TEST_ROOT/attacker-xdg-state"
  export MISE_NODE_MIRROR_URL="https://attacker.invalid/node"
  export MISE_PYTHON_COMPILE=1
  export MISE_BACKENDS="$TEST_ROOT/attacker-backends"
  export TMPDIR="$TEST_ROOT/attacker-tmp"
  export VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 0 ]
  assert_path_absent "$TEST_ROOT/attacker-data/hostile-write"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "mise-env:data=$HOME/.local/share/mise|cache=$HOME/.cache/mise|config=$PROJECT_ROOT/config"
  assert_file_contains "$VIBE_MAC_EVENT_LOG" \
    "|system=/dev/null|state=$HOME/.local/state/mise|tmp=/tmp|xdg_config=unset|xdg_data=unset|xdg_cache=unset|xdg_state=unset|node=unset|python=unset|backend=unset"
  run /usr/bin/grep -Fq 'mise-env-leak' "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "runtime verify не разрешает mise неявно скачать отсутствующий runtime" {
  make_fake_command mise '
    if [ "${1:-}" = -C ]; then
      shift 2
    fi
    case "${1:-}" in
      --version)
        printf "%s\n" "mise 2026.8.0"
        ;;
      where)
        item="${2:-}"
        name="${item%@*}"
        version="${item#*@}"
        root="$HOME/.local/share/mise/installs/$name/$version"
        if [ "${MISE_AUTO_INSTALL:-1}" != 0 ] ||
          [ "${MISE_EXEC_AUTO_INSTALL:-1}" != 0 ] ||
          [ "${MISE_OFFLINE:-0}" != 1 ]; then
          printf "%s\n" implicit-runtime-download >>"$VIBE_MAC_EVENT_LOG"
          mkdir -p "$root"
          printf "%s\n" "$root"
          exit 0
        fi
        exit 1
        ;;
      *) exit 2 ;;
    esac
  '
  /bin/cp "$TEST_ROOT/fake-bin/mise" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/mise"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" verify

  [ "$status" -eq 1 ]
  assert_path_absent "$HOME/.local/share/mise/installs/node/24.18.1"
  run /usr/bin/grep -Fq implicit-runtime-download "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}

@test "runtime verify в DRY_RUN не запускает mise или uv" {
  export DRY_RUN=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" verify

  [ "$status" -eq 1 ]
  [ ! -s "$VIBE_MAC_EVENT_LOG" ]
}

@test "runtime verify в DRY_RUN доверяет typed receipt и exact install paths" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
    manifest_record_runtime node "$NODE_VERSION" false true
    manifest_record_runtime python "$PYTHON_VERSION" false true
  '
  mkdir -p "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID"
  printf '%s\n' \
    'node|24.18.1|.local/share/mise/installs/node/24.18.1' \
    >"$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-node.created"
  printf '%s\n' \
    'python|3.12.13|.local/share/mise/installs/python/3.12.13' \
    >"$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-python.created"
  /bin/chmod 0600 \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-node.created" \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/runtime-python.created"
  node_bin="$HOME/.local/share/mise/installs/node/24.18.1/bin/node"
  python_bin="$HOME/.local/share/mise/installs/python/3.12.13/bin/python"
  mkdir -p "${node_bin%/*}" "${python_bin%/*}"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"$node_bin"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"$python_bin"
  /bin/chmod 0755 "$node_bin" "$python_bin"
  : >"$VIBE_MAC_EVENT_LOG"
  export DRY_RUN=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" verify

  [ "$status" -eq 0 ]
  [ ! -s "$VIBE_MAC_EVENT_LOG" ]
}

@test "runtime verify отклоняет impossible preexisting owned receipt" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
    manifest_record_runtime node "$NODE_VERSION" true true
    manifest_record_runtime python "$PYTHON_VERSION" true false
  '
  for spec in node/24.18.1/node python/3.12.13/python; do
    runtime_bin="$HOME/.local/share/mise/installs/${spec%/*}/bin/${spec##*/}"
    mkdir -p "${runtime_bin%/*}"
    printf '%s\n' '#!/bin/bash' 'exit 0' >"$runtime_bin"
    /bin/chmod 0755 "$runtime_bin"
  done
  export DRY_RUN=1

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" verify

  [ "$status" -eq 2 ]
  [ ! -s "$VIBE_MAC_EVENT_LOG" ]
}

@test "runtime commands изолированы от malicious global config miserc и backend" {
  mkdir -p "$HOME/.config/mise"
  printf '%s\n' \
    '[env]' \
    '_.source = "~/attacker-runtime-env.sh"' \
    >"$HOME/.config/mise/config.toml"
  printf '%s\n' 'experimental = true' >"$HOME/.config/mise/settings.toml"
  printf '%s\n' 'legacy_version_file = true' >"$HOME/.miserc"
  : >"$TEST_ROOT/check-mise-isolation"

  run /bin/bash "$PROJECT_ROOT/steps/50-runtimes.sh" apply

  [ "$status" -eq 0 ]
  assert_path_absent "$TEST_ROOT/malicious-config-executed"
  run /usr/bin/grep -Fq mise-config-leak "$VIBE_MAC_EVENT_LOG"
  [ "$status" -ne 0 ]
}
