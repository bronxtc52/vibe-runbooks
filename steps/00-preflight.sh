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
