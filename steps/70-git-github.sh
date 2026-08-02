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

git_tools_ready() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    # gh --version создаёт device-id на первом запуске, поэтому DRY_RUN
    # ограничивается безопасным поиском исполняемых файлов в PATH.
    have git && have gh
    return
  fi
  have git &&
    have gh &&
    git --version >/dev/null 2>&1 &&
    gh --version >/dev/null 2>&1
}

git_global_get() {
  git config --global --get "$1" 2>/dev/null
}

backup_git_config() {
  backup_file_once "$HOME/.gitconfig" gitconfig >/dev/null
}

set_git_default_if_missing() {
  local key value
  key="$1"
  value="$2"
  if git_global_get "$key" >/dev/null 2>&1; then
    return 0
  fi
  backup_git_config
  git config --global "$key" "$value"
}

maybe_set_identity() {
  local name email
  if ! git_global_get user.name >/dev/null 2>&1; then
    ui_info "Git user.name ещё не задан. Его можно безопасно отложить."
    if ui_confirm "Указать имя для локальных Git-коммитов сейчас?"; then
      if name="$(ui_prompt_value \
        "Имя для Git" \
        "${VIBE_MAC_TEST_GIT_NAME:-}")"; then
        backup_git_config
        git config --global user.name "$name"
      else
        ui_warn "Имя не задано."
      fi
    fi
  fi

  if ! git_global_get user.email >/dev/null 2>&1; then
    ui_info "Git user.email ещё не задан. Используй email, разрешённый GitHub."
    if ui_confirm "Указать email для локальных Git-коммитов сейчас?"; then
      if email="$(ui_prompt_value \
        "Email для Git" \
        "${VIBE_MAC_TEST_GIT_EMAIL:-}")"; then
        case "$email" in
          *@*.*)
            backup_git_config
            git config --global user.email "$email"
            ;;
          *)
            ui_warn "Email имеет неверный формат; значение не записано."
            ;;
        esac
      fi
    fi
  fi
}

maybe_login_github() {
  if gh auth status >/dev/null 2>&1; then
    ui_status "Уже стоит" "Вход GitHub уже выполнен."
    return 0
  fi
  ui_info "GitHub CLI откроет системный браузер; токен копировать в Терминал не нужно."
  if ! ui_confirm "Начать официальный вход GitHub?"; then
    ui_warn "Вход GitHub отложен."
    return 0
  fi
  gh auth login --web --git-protocol https
  if ! gh auth status >/dev/null 2>&1; then
    ui_warn "GitHub login пока не подтверждён; заверши его позже командой gh auth login."
  fi
}

apply_git_github() {
  if ! git_tools_ready; then
    ui_fail "Git или GitHub CLI не найдены; повтори шаг 30-brew-bundle."
    return 1
  fi

  set_git_default_if_missing init.defaultBranch main
  set_git_default_if_missing pull.rebase true
  set_git_default_if_missing push.autoSetupRemote true
  maybe_set_identity
  maybe_login_github
}

case "${1:-}" in
  plan)
    ui_info "Добавлю только отсутствующие Git defaults и предложу browser login GitHub."
    ;;
  detect|verify)
    git_tools_ready
    ;;
  apply)
    apply_git_github
    ;;
  *)
    ui_fail "70-git-github: неизвестное действие."
    exit 2
    ;;
esac
