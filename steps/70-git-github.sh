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

GIT_BIN=
GH_BIN=

step_expected_homebrew_prefix() {
  if is_test_mode; then
    if [ -n "${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" ]; then
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
  fi
  expected_homebrew_prefix
}

resolve_git_tools() {
  local prefix
  prefix="$(step_expected_homebrew_prefix)" || return 2
  GIT_BIN="$(homebrew_executable_in_prefix "$prefix" git)" || return "$?"
  GH_BIN="$(homebrew_executable_in_prefix "$prefix" gh)" || return "$?"
}

git_run() {
  local prefix clean_path run_user safe_cwd
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
  safe_cwd="$(cd /var/empty && pwd -P)" || return 2
  if is_test_mode; then
    (
      cd "$safe_cwd"
      /usr/bin/env -i \
        HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
        PATH="$clean_path" TMPDIR="${TMPDIR:-/tmp}" LC_ALL=C \
        VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
        VIBE_MAC_GIT_STATE="${VIBE_MAC_GIT_STATE:-}" \
        "$GIT_BIN" "$@"
    )
    return
  fi
  (
    cd "$safe_cwd"
    /usr/bin/env -i \
      HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
      PATH="$clean_path" TMPDIR=/tmp LC_ALL=C \
      "$GIT_BIN" "$@"
  )
}

gh_run() {
  local prefix clean_path run_user config_dir safe_cwd command_home command_tmp
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
  safe_cwd="$(cd /var/empty && pwd -P)" || return 2
  command_home="$HOME"
  if is_test_mode; then
    command_tmp="${TMPDIR:-/tmp}"
  else
    command_tmp=/tmp
  fi
  if [ "${DRY_RUN:-0}" = 1 ] || [ "${1:-}" = --version ]; then
    [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
    config_dir=/var/empty
    if [ "${1:-}" = --version ]; then
      command_home=/var/empty
      command_tmp=/var/empty
    fi
  else
    config_dir="$HOME/.config/gh"
    validate_home_dir_path "$config_dir" || return 2
  fi
  if is_test_mode; then
    (
      cd "$safe_cwd"
      /usr/bin/env -i \
        HOME="$command_home" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
        PATH="$clean_path" TMPDIR="$command_tmp" LC_ALL=C \
        GH_HOST=github.com GH_CONFIG_DIR="$config_dir" GH_PAGER=cat NO_COLOR=1 \
        GH_TELEMETRY=disabled DO_NOT_TRACK=1 \
        TEST_ROOT="${TEST_ROOT:-}" \
        VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
        VIBE_MAC_TEST_GH_LOGIN_FAIL="${VIBE_MAC_TEST_GH_LOGIN_FAIL:-0}" \
        "$GH_BIN" "$@"
    )
    return
  fi
  (
    cd "$safe_cwd"
    /usr/bin/env -i \
      HOME="$command_home" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
      PATH="$clean_path" TMPDIR="$command_tmp" LC_ALL=C \
      GH_HOST=github.com GH_CONFIG_DIR="$config_dir" GH_PAGER=cat NO_COLOR=1 \
      GH_TELEMETRY=disabled DO_NOT_TRACK=1 \
      "$GH_BIN" "$@"
  )
}

git_tools_ready() {
  resolve_git_tools || return "$?"
  if [ "${DRY_RUN:-0}" = "1" ] &&
    [ "${VIBE_MAC_FULL_VERIFY:-0}" != "1" ]; then
    return 0
  fi
  git_run --version >/dev/null 2>&1 || return "$?"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    # gh может создать device-id при первом запуске. gh_run направляет config
    # в штатный незаписываемый каталог macOS.
    gh_run --version >/dev/null 2>&1 || return "$?"
    return 0
  fi
  gh_run --version >/dev/null 2>&1 || return "$?"
}

git_global_get() {
  git_run config --global --get "$1" 2>/dev/null
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
  git_run config --global "$key" "$value"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  case "$key" in
    init.defaultBranch)
      manifest_record_git_default init-default-branch "$key" "$value"
      ;;
    pull.rebase)
      manifest_record_git_default pull-rebase "$key" "$value"
      ;;
    push.autoSetupRemote)
      manifest_record_git_default push-auto-upstream "$key" "$value"
      ;;
  esac
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
        git_run config --global user.name "$name"
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
            git_run config --global user.email "$email"
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
  local login_command status
  login_command="$(step_expected_homebrew_prefix)/bin/gh auth login --hostname github.com --web --git-protocol https"
  status=0
  gh_run auth status --hostname github.com >/dev/null 2>&1 || status="$?"
  case "$status" in
    0)
      ui_status "Уже стоит" "Вход GitHub уже выполнен."
      return 0
      ;;
    1) ;;
    *) return 2 ;;
  esac
  ui_info "GitHub CLI откроет системный браузер; токен копировать в Терминал не нужно."
  if ! ui_confirm "Начать официальный вход GitHub?"; then
    ui_warn "Вход GitHub отложен."
    return 0
  fi
  if ! gh_run auth login --hostname github.com --web --git-protocol https; then
    ui_warn "Вход GitHub не завершён. Повтори: $login_command"
    return 0
  fi
  status=0
  gh_run auth status --hostname github.com >/dev/null 2>&1 || status="$?"
  case "$status" in
    0) ;;
    1) ui_warn "Вход GitHub пока не подтверждён. Повтори: $login_command" ;;
    *) return 2 ;;
  esac
}

apply_git_github() {
  local ready_status
  if git_tools_ready; then
    :
  else
    ready_status="$?"
    ui_fail "Git или GitHub CLI не найдены; повтори шаг 30-brew-bundle."
    return "$ready_status"
  fi

  set_git_default_if_missing init.defaultBranch main
  set_git_default_if_missing pull.rebase true
  set_git_default_if_missing push.autoSetupRemote true
  maybe_set_identity
  maybe_login_github
}

case "${1:-}" in
  plan)
    ui_info "Добавлю только отсутствующие настройки Git и предложу вход в GitHub через системный браузер."
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
