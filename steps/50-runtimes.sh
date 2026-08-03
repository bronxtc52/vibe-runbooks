#!/usr/bin/env bash
set -euo pipefail

STEP_PATH="$(/bin/realpath "$0" 2>/dev/null)" || exit 2
STEP_DIR="${STEP_PATH%/*}"
VIBE_MAC_ROOT="${STEP_DIR%/*}"
export VIBE_MAC_ROOT

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

MISE_BIN=
UV_BIN=

step_expected_homebrew_prefix() {
  if is_test_mode &&
    [ -n "${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" ]; then
    case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
      /*)
        case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
          *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;;
        esac
        printf '%s\n' "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX"
        return 0
        ;;
      *) return 2 ;;
    esac
  fi
  expected_homebrew_prefix
}

required_homebrew_executable() {
  local name prefix bin candidate_path candidate status
  name="$1"
  case "$name" in
    mise|uv) ;;
    *) return 2 ;;
  esac
  prefix="$(step_expected_homebrew_prefix)" || return 2
  bin="$prefix/bin"
  candidate_path="$bin/$name"
  homebrew_env_files_safe "$prefix" || return 2
  if [ -L "$prefix" ] ||
    { [ -e "$prefix" ] && [ ! -d "$prefix" ]; } ||
    [ -L "$bin" ] || { [ -e "$bin" ] && [ ! -d "$bin" ]; }; then
    return 2
  fi
  status=0
  candidate="$(homebrew_executable_in_prefix "$prefix" "$name")" ||
    status="$?"
  if [ "$status" -eq 1 ] && [ -L "$candidate_path" ]; then
    status=2
  fi
  if [ "$status" -ne 0 ]; then
    ui_fail "Не найден безопасный Homebrew executable: $candidate_path."
    return "$status"
  fi
  printf '%s\n' "$candidate"
}

resolve_runtime_tools() {
  MISE_BIN="$(required_homebrew_executable mise)" || return "$?"
  UV_BIN="$(required_homebrew_executable uv)" || return "$?"
}

mise_run_with_global_config() {
  local global_config prefix clean_path run_user clean_tmp offline
  local trusted_config data_dir cache_dir state_dir
  global_config="$1"
  shift
  offline=1
  if [ "${1:-}" = install ]; then
    # Only the explicit, user-visible install operation may use the network.
    offline=0
  fi
  [ -n "$MISE_BIN" ] || return 2
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  clean_tmp=/tmp
  trusted_config="$VIBE_MAC_ROOT/config"
  data_dir="$HOME/.local/share/mise"
  cache_dir="$HOME/.cache/mise"
  state_dir="$HOME/.local/state/mise"
  [ -d "$trusted_config" ] && [ ! -L "$trusted_config" ] || return 2
  validate_home_dir_path "$data_dir" || return 2
  validate_home_dir_path "$cache_dir" || return 2
  validate_home_dir_path "$state_dir" || return 2
  case "$global_config" in
    /dev/null) ;;
    "$HOME/.config/mise/config.toml")
      validate_home_dir_path "${global_config%/*}" || return 2
      [ ! -e "$global_config" ] && [ ! -L "$global_config" ] || return 2
      ;;
    *) return 2 ;;
  esac

  if is_test_mode; then
    if [ "${VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR:-0}" != 1 ]; then
      clean_tmp="${TMPDIR:-/tmp}"
    fi
    /usr/bin/env -i \
      HOME="$HOME" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      PATH="$clean_path" \
      TMPDIR="$clean_tmp" \
      LANG=C \
      LC_ALL=C \
      MISE_YES=1 \
      MISE_AUTO_INSTALL=0 \
      MISE_EXEC_AUTO_INSTALL=0 \
      MISE_OFFLINE="$offline" \
      MISE_CONFIG_DIR="$trusted_config" \
      MISE_GLOBAL_CONFIG_FILE="$global_config" \
      MISE_SYSTEM_CONFIG_FILE=/dev/null \
      MISE_DATA_DIR="$data_dir" \
      MISE_CACHE_DIR="$cache_dir" \
      MISE_STATE_DIR="$state_dir" \
      MISE_TMP_DIR="$clean_tmp" \
      TEST_ROOT="${TEST_ROOT:-}" \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      VIBE_MAC_TEST_TRUSTED_CONFIG_DIR="$trusted_config" \
      "$MISE_BIN" -C "$trusted_config" "$@"
    return
  fi

  /usr/bin/env -i \
    HOME="$HOME" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    PATH="$clean_path" \
    TMPDIR="$clean_tmp" \
    LANG=C \
    LC_ALL=C \
    MISE_YES=1 \
    MISE_AUTO_INSTALL=0 \
    MISE_EXEC_AUTO_INSTALL=0 \
    MISE_OFFLINE="$offline" \
    MISE_CONFIG_DIR="$trusted_config" \
    MISE_GLOBAL_CONFIG_FILE="$global_config" \
    MISE_SYSTEM_CONFIG_FILE=/dev/null \
    MISE_DATA_DIR="$data_dir" \
    MISE_CACHE_DIR="$cache_dir" \
    MISE_STATE_DIR="$state_dir" \
    MISE_TMP_DIR=/tmp \
    "$MISE_BIN" -C "$trusted_config" "$@"
}

mise_run() {
  mise_run_with_global_config /dev/null "$@"
}

mise_global_run() {
  local global_config
  global_config="$HOME/.config/mise/config.toml"
  mise_run_with_global_config "$global_config" "$@"
}

runtime_receipt_entry_ready() {
  local name expected actual preexisting owned
  name="$1"
  expected="$2"
  actual="$(plutil_run -extract "runtimes.$name.version" raw \
    -expect string -- "$VIBE_MAC_MANIFEST_FILE" 2>/dev/null)" || return 2
  preexisting="$(plutil_run -extract "runtimes.$name.preexisting" raw \
    -expect bool -- "$VIBE_MAC_MANIFEST_FILE" 2>/dev/null)" || return 2
  owned="$(plutil_run -extract "runtimes.$name.owned" raw \
    -expect bool -- "$VIBE_MAC_MANIFEST_FILE" 2>/dev/null)" || return 2
  [ "$actual" = "$expected" ] || return 1
  case "$preexisting:$owned" in
    true:false) return 0 ;;
    false:true)
      runtime_creation_proof_matches "$name" "$expected" || return 2
      return 0
      ;;
    false:false) return 1 ;;
    *) return 2 ;;
  esac
}

runtime_dry_ready() {
  local data_root node_root python_root
  resolve_runtime_tools || return "$?"
  if [ ! -e "$VIBE_MAC_MANIFEST_FILE" ] && [ ! -L "$VIBE_MAC_MANIFEST_FILE" ]; then
    return 1
  fi
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] && [ ! -L "$VIBE_MAC_MANIFEST_FILE" ] ||
    return 2
  json_lint "$VIBE_MAC_MANIFEST_FILE" || return 2
  runtime_receipt_entry_ready node "$NODE_VERSION" || return "$?"
  runtime_receipt_entry_ready python "$PYTHON_VERSION" || return "$?"

  data_root="$HOME/.local/share/mise/installs"
  node_root="$data_root/node/$NODE_VERSION"
  python_root="$data_root/python/$PYTHON_VERSION"
  validate_home_dir_path "$node_root" || return 2
  validate_home_dir_path "$python_root" || return 2
  [ -d "$node_root" ] && [ ! -L "$node_root" ] || return 1
  [ -d "$python_root" ] && [ ! -L "$python_root" ] || return 1
  [ -f "$node_root/bin/node" ] && [ -x "$node_root/bin/node" ] || return 1
  [ -f "$python_root/bin/python" ] && [ -x "$python_root/bin/python" ] ||
    return 1
}

runtime_ready() {
  local mise_output mise_version uv_output
  if [ "${DRY_RUN:-0}" = 1 ]; then
    runtime_dry_ready
    return
  fi
  resolve_runtime_tools || return "$?"
  mise_output="$(mise_run --version 2>/dev/null)" || return 1
  mise_version="$(printf '%s\n' "$mise_output" |
    /usr/bin/grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' |
    /usr/bin/head -n 1)"
  [ -n "$mise_version" ] || return 1
  version_at_least "$mise_version" "$MISE_MIN_TESTED_VERSION" || return 1
  runtime_probe_exact node "$NODE_VERSION" || return "$?"
  runtime_probe_exact python "$PYTHON_VERSION" || return "$?"
  uv_output="$("$UV_BIN" --version 2>/dev/null)" || return 1
  case "$uv_output" in
    "uv "*) true ;;
    *) false ;;
  esac
}

runtime_creation_proof_path() {
  local name install_id
  name="$1"
  case "$name" in node|python) ;; *) return 2 ;; esac
  install_id="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" install_id 2>/dev/null)" || return 2
  validate_logical_id "$install_id" || return 2
  printf '%s/%s/runtime-%s.created\n' \
    "$VIBE_MAC_BACKUP_ROOT" "$install_id" "$name"
}

runtime_creation_proof_expected() {
  local name version
  name="$1"
  version="$2"
  case "$name" in node|python) ;; *) return 2 ;; esac
  printf '%s|%s|.local/share/mise/installs/%s/%s\n' \
    "$name" "$version" "$name" "$version"
}

runtime_creation_proof_matches() {
  local name version proof expected actual
  name="$1"
  version="$2"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 1
  proof="$(runtime_creation_proof_path "$name")" || return 2
  validate_home_dir_path "${proof%/*}" || return 2
  if [ ! -e "$proof" ] && [ ! -L "$proof" ]; then
    return 1
  fi
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
  expected="$(runtime_creation_proof_expected "$name" "$version")" ||
    return 2
  actual="$(/bin/cat "$proof")" || return 2
  [ "$actual" = "$expected" ]
}

write_runtime_creation_proof() {
  local name version proof parent expected existing temp
  name="$1"
  version="$2"
  proof="$(runtime_creation_proof_path "$name")" || return 2
  parent="${proof%/*}"
  validate_home_dir_path "$parent" || return 2
  ensure_home_dir "$parent" || return 2
  /bin/chmod 0700 "$parent"
  expected="$(runtime_creation_proof_expected "$name" "$version")" ||
    return 2
  if [ -e "$proof" ] || [ -L "$proof" ]; then
    [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
    existing="$(/bin/cat "$proof")" || return 2
    [ "$existing" = "$expected" ] || return 2
    /bin/chmod 0600 "$proof"
    return 0
  fi
  temp="$(/usr/bin/mktemp "$parent/.runtime-proof.XXXXXX")"
  if ! printf '%s\n' "$expected" >"$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  if ! /bin/ln "$temp" "$proof"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/unlink "$temp"
}

runtime_manifest_state() {
  local name expected version preexisting owned proof_status
  name="$1"
  expected="$2"
  version="$(plutil_run -extract "runtimes.$name.version" raw \
    -expect string -- "$VIBE_MAC_MANIFEST_FILE" 2>/dev/null)" || return 2
  preexisting="$(plutil_run -extract "runtimes.$name.preexisting" raw \
    -expect bool -- "$VIBE_MAC_MANIFEST_FILE" 2>/dev/null)" || return 2
  owned="$(plutil_run -extract "runtimes.$name.owned" raw \
    -expect bool -- "$VIBE_MAC_MANIFEST_FILE" 2>/dev/null)" || return 2
  case "$preexisting:$owned" in
    true:false)
      [ "$version" = "$expected" ] || return 2
      printf '%s\n' preexisting
      ;;
    false:true)
      [ "$version" = "$expected" ] || return 2
      if runtime_creation_proof_matches "$name" "$expected"; then
        printf '%s\n' owned
      else
        proof_status="$?"
        [ "$proof_status" -eq 1 ] || return 2
        printf '%s\n' unproven-owned
      fi
      ;;
    false:false)
      [ -z "$version" ] || [ "$version" = "$expected" ] || return 2
      printf '%s\n' empty
      ;;
    *)
      return 2
      ;;
  esac
}

runtime_probe_exact() {
  local name version item expected_path reported_path command expected_output
  local actual_output
  name="$1"
  version="$2"
  item="$name@$version"
  expected_path="$HOME/.local/share/mise/installs/$name/$version"
  validate_home_dir_path "$expected_path" || return 2
  if ! reported_path="$(mise_run where "$item" 2>/dev/null)"; then
    if [ ! -e "$expected_path" ] && [ ! -L "$expected_path" ]; then
      return 1
    fi
    return 2
  fi
  [ "$reported_path" = "$expected_path" ] || return 2
  [ -d "$expected_path" ] && [ ! -L "$expected_path" ] || return 2
  case "$name" in
    node)
      command=node
      expected_output="v$version"
      ;;
    python)
      command=python
      expected_output="Python $version"
      ;;
    *) return 2 ;;
  esac
  actual_output="$(mise_run \
    exec "$item" -- "$command" --version 2>/dev/null)" || return 2
  [ "$actual_output" = "$expected_output" ] || return 2
}

prepare_runtime_state() {
  local name version probe_status manifest_state
  name="$1"
  version="$2"
  RUNTIME_PREPARED_STATE=untracked
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  manifest_state="$(runtime_manifest_state "$name" "$version")" || return 2
  if runtime_probe_exact "$name" "$version"; then
    if [ "$manifest_state" = owned ]; then
      RUNTIME_PREPARED_STATE=owned
    else
      manifest_record_runtime "$name" "$version" true false
      RUNTIME_PREPARED_STATE=preexisting
    fi
    return 0
  else
    probe_status="$?"
  fi
  [ "$probe_status" -eq 1 ] || return 2
  manifest_record_runtime "$name" "$version" false false
  RUNTIME_PREPARED_STATE=new
}

record_runtime_after_install() {
  local name version state
  name="$1"
  version="$2"
  state="$3"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  case "$state" in
    owned)
      runtime_creation_proof_matches "$name" "$version" || return 2
      manifest_record_runtime "$name" "$version" false true
      ;;
    preexisting)
      manifest_record_runtime "$name" "$version" true false
      ;;
    new)
      write_runtime_creation_proof "$name" "$version"
      manifest_record_runtime "$name" "$version" false true
      ;;
    untracked) ;;
    *) return 2 ;;
  esac
}

settle_failed_runtime() {
  local name version state probe_status
  name="$1"
  version="$2"
  state="$3"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  case "$state" in
    owned)
      runtime_creation_proof_matches "$name" "$version" || return 2
      manifest_record_runtime "$name" "$version" false true
      ;;
    preexisting)
      manifest_record_runtime "$name" "$version" true false
      ;;
    new)
      if runtime_probe_exact "$name" "$version"; then
        manifest_record_runtime "$name" "$version" true false
      else
        probe_status="$?"
        case "$probe_status" in
          1) manifest_record_runtime "$name" "$version" false false ;;
          2) manifest_record_runtime "$name" "$version" true false ;;
          *) return 2 ;;
        esac
      fi
      ;;
    untracked) ;;
    *) return 2 ;;
  esac
}

mise_global_creation_proof_path() {
  validate_logical_id "${VIBE_MAC_INSTALL_ID:-}" || return 2
  printf '%s/%s/%s\n' \
    "$VIBE_MAC_BACKUP_ROOT" \
    "$VIBE_MAC_INSTALL_ID" \
    mise-global.created-sha256
}

write_mise_global_creation_proof() {
  local backup_dir config evidence existing proof sha temp
  config="$HOME/.config/mise/config.toml"
  proof="$(mise_global_creation_proof_path)" || return 2
  backup_dir="${proof%/*}"
  validate_home_dir_path "$backup_dir" || return 2
  [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 2
  evidence="$(backup_evidence_kind mise-global)" || return 2
  [ "$evidence" = absent ] || return 2
  [ -f "$config" ] && [ ! -L "$config" ] || return 2
  sha="$(sha256_file "$config")" || return 2
  validate_sha256_or_empty "$sha" && [ -n "$sha" ] || return 2

  if [ -e "$proof" ] || [ -L "$proof" ]; then
    [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
    existing="$(/bin/cat "$proof")" || return 2
    validate_sha256_or_empty "$existing" && [ -n "$existing" ] || return 2
    [ "$existing" = "$sha" ] || return 2
    return 0
  fi

  temp="$(/usr/bin/mktemp "$backup_dir/.mise-global-proof.XXXXXX")"
  if ! printf '%s\n' "$sha" >"$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  if ! /bin/ln "$temp" "$proof"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/unlink "$temp"
}

mise_global_creation_proof_matches() {
  local config expected proof actual
  config="$HOME/.config/mise/config.toml"
  proof="$(mise_global_creation_proof_path)" || return 2
  validate_home_dir_path "${proof%/*}" || return 2
  if [ ! -e "$proof" ] && [ ! -L "$proof" ]; then
    return 1
  fi
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
  [ -f "$config" ] && [ ! -L "$config" ] || return 2
  expected="$(/bin/cat "$proof")" || return 2
  validate_sha256_or_empty "$expected" && [ -n "$expected" ] || return 2
  actual="$(sha256_file "$config")" || return 2
  [ "$actual" = "$expected" ]
}

record_mise_global_if_evidence() {
  local evidence owned preexisting proof_status status
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  if json_extract_raw "$VIBE_MAC_MANIFEST_FILE" files.mise-global.owned >/dev/null 2>&1; then
    return 0
  fi
  if evidence="$(backup_evidence_kind mise-global)"; then
    :
  else
    status="$?"
    [ "$status" -eq 1 ] && return 0
    return 2
  fi
  [ "$evidence" = absent ] || return 2
  if mise_global_creation_proof_matches; then
    preexisting=false
    owned=true
  else
    proof_status="$?"
    [ "$proof_status" -eq 1 ] || return 2
    preexisting=true
    owned=false
  fi
  manifest_record_file mise-global .config/mise/config.toml owned_file "" \
    "$preexisting" "$owned" \
    "$(sha256_file "$HOME/.config/mise/config.toml")" mise-global
}

apply_runtimes() {
  local global_config global_parent node_state python_state tools_status
  local probe_status
  if resolve_runtime_tools; then
    :
  else
    tools_status="$?"
    ui_fail "Сначала нужен шаг 30-brew-bundle с mise и uv."
    return "$tools_status"
  fi

  global_config="$HOME/.config/mise/config.toml"
  global_parent="${global_config%/*}"
  home_relative_from_absolute "$global_config" >/dev/null || return 2
  validate_home_dir_path "$global_parent" || return 2
  if [ -L "$global_config" ]; then
    ui_fail "Global mise config является symlink; не меняю его."
    return 2
  fi
  if [ -e "$global_config" ] && [ ! -f "$global_config" ]; then
    ui_fail "Global mise config занят не обычным файлом."
    return 2
  fi

  prepare_runtime_state node "$NODE_VERSION"
  node_state="$RUNTIME_PREPARED_STATE"
  prepare_runtime_state python "$PYTHON_VERSION"
  python_state="$RUNTIME_PREPARED_STATE"

  if is_test_mode &&
    [ "${VIBE_MAC_TEST_CRASH_BEFORE_RUNTIME_INSTALL:-0}" = 1 ]; then
    return 90
  fi

  if ! mise_run install "node@$NODE_VERSION" "python@$PYTHON_VERSION"; then
    settle_failed_runtime node "$NODE_VERSION" "$node_state"
    settle_failed_runtime python "$PYTHON_VERSION" "$python_state"
    return 1
  fi

  if runtime_probe_exact node "$NODE_VERSION"; then
    :
  else
    probe_status="$?"
    settle_failed_runtime node "$NODE_VERSION" "$node_state"
    settle_failed_runtime python "$PYTHON_VERSION" "$python_state"
    [ "$probe_status" -eq 1 ] && return 1
    return 2
  fi
  if runtime_probe_exact python "$PYTHON_VERSION"; then
    :
  else
    probe_status="$?"
    settle_failed_runtime node "$NODE_VERSION" "$node_state"
    settle_failed_runtime python "$PYTHON_VERSION" "$python_state"
    [ "$probe_status" -eq 1 ] && return 1
    return 2
  fi
  if is_test_mode &&
    [ "${VIBE_MAC_TEST_CRASH_AFTER_RUNTIME_INSTALL:-0}" = 1 ]; then
    return 93
  fi
  record_runtime_after_install node "$NODE_VERSION" "$node_state"
  record_runtime_after_install python "$PYTHON_VERSION" "$python_state"

  if [ ! -e "$global_config" ]; then
    backup_file_once "$global_config" mise-global >/dev/null
    if is_test_mode &&
      [ "${VIBE_MAC_TEST_CRASH_AFTER_MISE_GLOBAL_EVIDENCE:-0}" = 1 ]; then
      return 92
    fi
    mise_global_run \
      use --global --pin "node@$NODE_VERSION" "python@$PYTHON_VERSION"
    write_mise_global_creation_proof
    if is_test_mode && [ "${VIBE_MAC_TEST_CRASH_AFTER_MISE_USE:-0}" = 1 ]; then
      return 91
    fi
  fi

  runtime_ready
  record_mise_global_if_evidence
}

case "${1:-}" in
  plan)
    ui_info "Установлю Node.js $NODE_VERSION и Python $PYTHON_VERSION через mise."
    ;;
  detect|verify)
    runtime_ready
    ;;
  apply)
    apply_runtimes
    ;;
  *)
    ui_fail "50-runtimes: неизвестное действие."
    exit 2
    ;;
esac
