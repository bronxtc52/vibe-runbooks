#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VIBE_MAC_ROOT="${VIBE_MAC_ROOT:-$(cd "$STEP_DIR/.." && pwd -P)}"
export VIBE_MAC_ROOT

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"

runtime_ready() {
  local mise_output mise_version node_output python_output uv_output
  have mise || return 1
  have uv || return 1
  mise_output="$(mise --version 2>/dev/null)" || return 1
  mise_version="$(printf '%s\n' "$mise_output" |
    /usr/bin/grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' |
    /usr/bin/head -n 1)"
  [ -n "$mise_version" ] || return 1
  version_at_least "$mise_version" "$MISE_MIN_TESTED_VERSION" || return 1
  mise where "node@$NODE_VERSION" >/dev/null 2>&1 || return 1
  mise where "python@$PYTHON_VERSION" >/dev/null 2>&1 || return 1
  node_output="$(mise exec "node@$NODE_VERSION" -- node --version 2>/dev/null)" ||
    return 1
  python_output="$(mise exec "python@$PYTHON_VERSION" -- python --version 2>&1)" ||
    return 1
  uv_output="$(uv --version 2>/dev/null)" || return 1
  [ "$node_output" = "v$NODE_VERSION" ] &&
    [ "$python_output" = "Python $PYTHON_VERSION" ] &&
    case "$uv_output" in
      "uv "*) true ;;
      *) false ;;
    esac
}

apply_runtimes() {
  local global_config node_preexisting python_preexisting global_preexisting
  if ! have mise || ! have uv; then
    ui_fail "Сначала нужен шаг 30-brew-bundle с mise и uv."
    return 1
  fi

  node_preexisting=false
  python_preexisting=false
  global_preexisting=false
  mise where "node@$NODE_VERSION" >/dev/null 2>&1 &&
    node_preexisting=true
  mise where "python@$PYTHON_VERSION" >/dev/null 2>&1 &&
    python_preexisting=true

  MISE_YES=1 mise install \
    "node@$NODE_VERSION" \
    "python@$PYTHON_VERSION"

  global_config="$HOME/.config/mise/config.toml"
  if [ -L "$global_config" ]; then
    ui_fail "Global mise config является symlink; не меняю его."
    return 2
  fi
  if [ ! -e "$global_config" ]; then
    backup_file_once "$global_config" mise-global >/dev/null
    MISE_YES=1 mise use --global --pin \
      "node@$NODE_VERSION" \
      "python@$PYTHON_VERSION"
  elif [ ! -f "$global_config" ]; then
    ui_fail "Global mise config занят не обычным файлом."
    return 2
  else
    global_preexisting=true
  fi

  runtime_ready
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  if [ "$node_preexisting" = true ]; then
    manifest_record_runtime node "$NODE_VERSION" true false
  else
    manifest_record_runtime node "$NODE_VERSION" false true
  fi
  if [ "$python_preexisting" = true ]; then
    manifest_record_runtime python "$PYTHON_VERSION" true false
  else
    manifest_record_runtime python "$PYTHON_VERSION" false true
  fi
  if [ "$global_preexisting" = false ]; then
    manifest_record_file \
      mise-global .config/mise/config.toml owned_file "" false true \
      "$(sha256_file "$global_config")" mise-global
  fi
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
