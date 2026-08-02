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

clt_installed() {
  local selected
  if is_test_mode; then
    if [ -n "${VIBE_MAC_TEST_CLT_MARKER:-}" ]; then
      [ -f "$VIBE_MAC_TEST_CLT_MARKER" ]
      return
    fi
    [ "${VIBE_MAC_TEST_CLT:-missing}" = "installed" ]
    return
  fi
  /usr/sbin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1 ||
    return 1
  selected="$(/usr/bin/xcode-select -p 2>/dev/null)" || return 1
  [ -n "$selected" ] && [ -d "$selected" ]
}

install_clt() {
  local poll max_polls interval
  if clt_installed; then
    return 0
  fi

  ui_info "Command Line Tools — это около 1 ГБ базовых утилит, не Xcode.app."
  if ! ui_pause "Сейчас macOS покажет своё системное окно установки."; then
    return 1
  fi

  if is_test_mode; then
    printf '%s\n' "xcode-select --install" >>"$VIBE_MAC_EVENT_LOG"
    if [ -n "${VIBE_MAC_TEST_CLT_MARKER:-}" ]; then
      : >"$VIBE_MAC_TEST_CLT_MARKER"
    fi
    return 0
  fi

  /usr/bin/xcode-select --install 2>/dev/null || true
  max_polls="${VIBE_MAC_CLT_MAX_POLLS:-360}"
  interval="${VIBE_MAC_CLT_POLL_SECONDS:-5}"
  poll=1
  while [ "$poll" -le "$max_polls" ]; do
    if clt_installed; then
      return 0
    fi
    printf '[%s/%s] Жду завершения Command Line Tools…\n' "$poll" "$max_polls"
    /bin/sleep "$interval"
    poll=$((poll + 1))
  done
  ui_fail "Command Line Tools не завершили установку вовремя."
  return 1
}

case "${1:-}" in
  plan)
    ui_info "Установлю только Xcode Command Line Tools через системное окно."
    ;;
  detect|verify)
    clt_installed
    ;;
  apply)
    install_clt
    ;;
  *)
    ui_fail "10-xcode-clt: неизвестное действие."
    exit 2
    ;;
esac
