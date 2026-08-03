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

action="${1:-}"

case "$action" in
  plan)
    ui_info "Проверю macOS 14+, Apple Silicon, место и доступность источников."
    ;;
  detect|verify)
    guard_preflight
    ;;
  apply)
    guard_preflight
    ;;
  *)
    ui_fail "00-preflight: неизвестное действие."
    exit 2
    ;;
esac
