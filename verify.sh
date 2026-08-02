#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VIBE_MAC_ROOT="$SCRIPT_DIR"
export VIBE_MAC_ROOT

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"

READY_COUNT=0
FAILED_COUNT=0
FATAL_ERROR=0
REPAIR_COMMAND="/bin/bash \"$HOME/.vibe-mac/current/install.sh\""

usage() {
  printf '%s\n' "Запуск: /bin/bash ./verify.sh"
}

run_step_verify() {
  DRY_RUN=1 /bin/bash "$VIBE_MAC_ROOT/steps/$1.sh" verify
}

probe_clt() {
  run_step_verify 10-xcode-clt
}

probe_homebrew() {
  run_step_verify 20-homebrew
}

probe_git_gh() {
  run_step_verify 70-git-github
}

probe_ghostty() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_GHOSTTY_APP:-}" ]; then
    [ -d "$VIBE_MAC_TEST_GHOSTTY_APP" ]
  else
    [ -d /Applications/Ghostty.app ]
  fi
}

probe_shell() {
  local font_dir
  run_step_verify 40-shell || return
  if is_test_mode && [ -n "${VIBE_MAC_TEST_FONT_DIR:-}" ]; then
    font_dir="$VIBE_MAC_TEST_FONT_DIR"
  else
    font_dir="$HOME/Library/Fonts"
  fi
  [ -d "$font_dir" ] || return 1
  /usr/bin/find "$font_dir" -maxdepth 1 -type f \
    \( -iname 'JetBrainsMono*NerdFont*.ttf' -o \
       -iname 'JetBrainsMono*NerdFont*.otf' \) -print -quit |
    /usr/bin/grep -q .
}

probe_cli_set() {
  local command_name
  for command_name in rg fd fzf bat eza jq tree zoxide; do
    have "$command_name" || return 1
  done
}

probe_mise() {
  local output version
  have mise || return 1
  output="$(mise --version 2>/dev/null)" || return 1
  version="$(printf '%s\n' "$output" |
    /usr/bin/grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' |
    /usr/bin/head -n 1)"
  [ -n "$version" ] || return 1
  version_at_least "$version" "$MISE_MIN_TESTED_VERSION" || return 1
  /usr/bin/grep -Fq 'mise activate zsh --shims' "$HOME/.zprofile" &&
    /usr/bin/grep -Fq 'mise activate zsh' "$HOME/.zshrc"
}

probe_node() {
  local output
  [ -d "$HOME/dev/hello-vibe" ] || return 1
  output="$(mise -C "$HOME/dev/hello-vibe" exec -- node --version 2>/dev/null)" ||
    return 1
  [ "$output" = "v$NODE_VERSION" ]
}

probe_python() {
  local output
  [ -d "$HOME/dev/hello-vibe" ] || return 1
  output="$(mise -C "$HOME/dev/hello-vibe" exec -- python --version 2>&1)" ||
    return 1
  [ "$output" = "Python $PYTHON_VERSION" ]
}

probe_uv() {
  local output
  have uv || return 1
  output="$(uv --version 2>/dev/null)" || return 1
  case "$output" in
    "uv "[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

probe_ai() {
  run_step_verify 60-ai-agents
}

probe_workspace() {
  run_step_verify 90-workspace
}

emit_probe() {
  local name result
  name="$1"
  result="$2"
  case "$result" in
    0)
      READY_COUNT=$((READY_COUNT + 1))
      ui_status "Уже стоит" "$name"
      ;;
    1)
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ui_status "Ошибка" "$name"
      printf '  Исправить: %s\n' "$REPAIR_COMMAND"
      ;;
    2)
      FATAL_ERROR=1
      ui_status "Ошибка" "$name: проверка не смогла выполниться"
      ;;
    *)
      FATAL_ERROR=1
      ui_status "Ошибка" "$name: неизвестный результат"
      ;;
  esac
}

call_probe() {
  local name function_name status
  name="$1"
  function_name="$2"
  if "$function_name" >/dev/null 2>&1; then
    status=0
  else
    status="$?"
    case "$status" in
      1) ;;
      *) status=2 ;;
    esac
  fi
  emit_probe "$name" "$status"
}

run_test_probes() {
  local results value
  results="$VIBE_MAC_TEST_VERIFY_RESULTS"
  # Intentional word splitting: contract is exactly twelve 0/1 tokens.
  # shellcheck disable=SC2086
  set -- $results
  if [ "$#" -ne 12 ]; then
    ui_fail "Некорректные test probes: ожидалось 12 значений."
    return 2
  fi
  for value in "$@"; do
    case "$value" in 0|1) ;; *)
      ui_fail "Некорректные test probes: разрешены только 0/1."
      return 2
    esac
  done
  emit_probe "Xcode Command Line Tools" "$([ "$1" = 1 ] && printf 0 || printf 1)"
  emit_probe "Homebrew" "$([ "$2" = 1 ] && printf 0 || printf 1)"
  emit_probe "Git и GitHub CLI" "$([ "$3" = 1 ] && printf 0 || printf 1)"
  emit_probe "Ghostty" "$([ "$4" = 1 ] && printf 0 || printf 1)"
  emit_probe "zsh, Oh My Zsh, Starship и шрифт" "$([ "$5" = 1 ] && printf 0 || printf 1)"
  emit_probe "CLI-набор" "$([ "$6" = 1 ] && printf 0 || printf 1)"
  emit_probe "mise и shell activation" "$([ "$7" = 1 ] && printf 0 || printf 1)"
  emit_probe "Node.js" "$([ "$8" = 1 ] && printf 0 || printf 1)"
  emit_probe "Python" "$([ "$9" = 1 ] && printf 0 || printf 1)"
  emit_probe "uv" "$([ "${10}" = 1 ] && printf 0 || printf 1)"
  emit_probe "AI CLI и Cursor" "$([ "${11}" = 1 ] && printf 0 || printf 1)"
  emit_probe "Workspace и доктрина" "$([ "${12}" = 1 ] && printf 0 || printf 1)"
}

auth_status() {
  local label status_function
  label="$1"
  status_function="$2"
  if "$status_function"; then
    printf '• Вход %s: выполнен\n' "$label"
  else
    printf '• Вход %s: нужен или не подтверждён\n' "$label"
  fi
}

gh_authenticated() {
  gh auth status >/dev/null 2>&1
}

claude_authenticated() {
  claude auth status --text >/dev/null 2>&1
}

codex_authenticated() {
  codex login status >/dev/null 2>&1
}

cursor_authenticated() {
  cursor-agent status >/dev/null 2>&1
}

run_real_probes() {
  call_probe "Xcode Command Line Tools" probe_clt
  call_probe "Homebrew" probe_homebrew
  call_probe "Git и GitHub CLI" probe_git_gh
  call_probe "Ghostty" probe_ghostty
  call_probe "zsh, Oh My Zsh, Starship и шрифт" probe_shell
  call_probe "CLI-набор" probe_cli_set
  call_probe "mise и shell activation" probe_mise
  call_probe "Node.js" probe_node
  call_probe "Python" probe_python
  call_probe "uv" probe_uv
  call_probe "AI CLI и Cursor" probe_ai
  call_probe "Workspace и доктрина" probe_workspace
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if is_test_mode && [ -n "${VIBE_MAC_TEST_VERIFY_RESULTS:-}" ]; then
  run_test_probes || exit 2
else
  run_real_probes
fi

printf '\n%s из 12 готово.\n' "$READY_COUNT"
if is_test_mode; then
  printf '• Входы: не вызываются в sandbox-проверке.\n'
else
  printf '\nСтатусы входов (не влияют на 12 технических критериев):\n'
  auth_status GitHub gh_authenticated
  auth_status Claude claude_authenticated
  auth_status Codex codex_authenticated
  auth_status "Cursor Agent" cursor_authenticated
  printf '• Вход Cursor Desktop: проверь вручную в приложении.\n'
fi

if [ "$FATAL_ERROR" -ne 0 ]; then
  exit 2
fi
if [ "$FAILED_COUNT" -ne 0 ]; then
  exit 1
fi
