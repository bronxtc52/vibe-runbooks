#!/usr/bin/env bash
set -euo pipefail

STEP_PATH="$(/bin/realpath "$0" 2>/dev/null)" || exit 2
STEP_DIR="${STEP_PATH%/*}"
VIBE_MAC_ROOT="${STEP_DIR%/*}"
export VIBE_MAC_ROOT

# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

WORKSPACE="$HOME/dev/hello-vibe"
WORKSPACE_STAGING=
GIT_BIN=

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

resolve_workspace_git() {
  local prefix candidate status
  prefix="$(step_expected_homebrew_prefix)" || return 2
  status=0
  candidate="$(homebrew_executable_in_prefix "$prefix" git)" || status="$?"
  if [ "$status" -ne 0 ]; then
    ui_fail "Не найден безопасный Homebrew executable: $prefix/bin/git."
    return "$status"
  fi
  GIT_BIN="$candidate"
}

workspace_git_run() {
  local prefix clean_path run_user
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  if is_test_mode; then
    /usr/bin/env -i \
      HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
      PATH="$clean_path" TMPDIR="${TMPDIR:-/tmp}" LC_ALL=C \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      "$GIT_BIN" "$@"
    return
  fi
  /usr/bin/env -i \
    HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
    PATH="$clean_path" TMPDIR=/tmp LC_ALL=C \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$GIT_BIN" "$@"
}

workspace_ready() {
  local branch remote
  [ -d "$WORKSPACE" ] || return 1
  [ ! -L "$WORKSPACE" ] || return 1
  [ -f "$WORKSPACE/index.html" ] && [ ! -L "$WORKSPACE/index.html" ] ||
    return 1
  [ -f "$WORKSPACE/AGENTS.md" ] && [ ! -L "$WORKSPACE/AGENTS.md" ] ||
    return 1
  [ -f "$WORKSPACE/CLAUDE.md" ] && [ ! -L "$WORKSPACE/CLAUDE.md" ] ||
    return 1
  [ -f "$WORKSPACE/FIRST-PROMPT.md" ] &&
    [ ! -L "$WORKSPACE/FIRST-PROMPT.md" ] || return 1
  [ -f "$WORKSPACE/.mise.toml" ] && [ ! -L "$WORKSPACE/.mise.toml" ] ||
    return 1
  /usr/bin/cmp -s "$VIBE_MAC_ROOT/config/AGENTS.md" "$WORKSPACE/AGENTS.md" ||
    return 1
  /usr/bin/cmp -s "$VIBE_MAC_ROOT/config/CLAUDE.md" "$WORKSPACE/CLAUDE.md" ||
    return 1
  /usr/bin/cmp -s "$VIBE_MAC_ROOT/config/mise.toml" "$WORKSPACE/.mise.toml" ||
    return 1
  /usr/bin/cmp -s \
    "$VIBE_MAC_ROOT/config/FIRST-PROMPT.md" \
    "$WORKSPACE/FIRST-PROMPT.md" || return 1
  [ -d "$WORKSPACE/.git" ] && [ ! -L "$WORKSPACE/.git" ] || return 1
  resolve_workspace_git || return "$?"
  branch="$(workspace_git_run \
    -C "$WORKSPACE" branch --show-current 2>/dev/null)" ||
    return 1
  [ "$branch" = "feat/first-page" ] || return 1
  remote="$(workspace_git_run -C "$WORKSPACE" remote 2>/dev/null)" ||
    return 1
  [ -z "$remote" ] || return 1
}

cleanup_workspace_staging() {
  local expected_prefix
  [ -n "$WORKSPACE_STAGING" ] || return 0
  expected_prefix="$HOME/dev/.hello-vibe.vibe-mac."
  case "$WORKSPACE_STAGING" in
    "$expected_prefix"*)
      ;;
    *)
      ui_fail "Отказ от очистки неожиданного staging path."
      return 2
      ;;
  esac
  if [ -d "$WORKSPACE_STAGING" ] && [ ! -L "$WORKSPACE_STAGING" ]; then
    /usr/bin/find "$WORKSPACE_STAGING" -depth -delete
  fi
  WORKSPACE_STAGING=
}

write_workspace_files() {
  /bin/cp "$VIBE_MAC_ROOT/config/AGENTS.md" "$WORKSPACE_STAGING/AGENTS.md"
  /bin/cp "$VIBE_MAC_ROOT/config/CLAUDE.md" "$WORKSPACE_STAGING/CLAUDE.md"
  /bin/cp "$VIBE_MAC_ROOT/config/mise.toml" "$WORKSPACE_STAGING/.mise.toml"
  /bin/cp \
    "$VIBE_MAC_ROOT/config/FIRST-PROMPT.md" \
    "$WORKSPACE_STAGING/FIRST-PROMPT.md"

  /bin/cat >"$WORKSPACE_STAGING/index.html" <<'HTML'
<!doctype html>
<html lang="ru">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Моя первая страница</title>
    <style>
      body {
        max-width: 42rem;
        margin: 5rem auto;
        padding: 0 1.5rem;
        font: 18px/1.6 system-ui, sans-serif;
        color: #172033;
        background: #f5f7fb;
      }
    </style>
  </head>
  <body>
    <h1>Привет! Всё работает.</h1>
    <p>Это твоя первая локальная страница для вайбкодинга.</p>
  </body>
</html>
HTML

}

open_workspace_page() {
  local open_bin run_user safe_cwd
  if ! ui_pause "Проект готов. Сейчас открою локальную страницу в системном браузере."; then
    ui_warn "Страница не открыта автоматически. Файлы проекта уже готовы."
    return 0
  fi
  if is_test_mode; then
    open_bin="${VIBE_MAC_OPEN_BIN:?test open не задан}"
  else
    open_bin=/usr/bin/open
  fi
  run_user="$(/usr/bin/id -un)" || return 2
  [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
  safe_cwd="$(cd /var/empty && pwd -P)" || return 2
  if is_test_mode; then
    if ! (
      cd "$safe_cwd"
      /usr/bin/env -i \
        HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        TMPDIR="${TMPDIR:-/tmp}" LC_ALL=C \
        VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
        "$open_bin" "$WORKSPACE/index.html"
    ); then
      ui_warn "Страница не открылась автоматически. Открой $WORKSPACE/index.html двойным кликом."
    fi
    return 0
  fi
  if ! (
    cd "$safe_cwd"
    /usr/bin/env -i \
      HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp LC_ALL=C \
      "$open_bin" "$WORKSPACE/index.html"
  ); then
    ui_warn "Страница не открылась автоматически. Открой $WORKSPACE/index.html двойным кликом."
  fi
  return 0
}

print_first_prompt() {
  local prefix
  prefix="$(step_expected_homebrew_prefix)" || return 2
  printf '\n%s\n\n' "Первый промпт для Claude:"
  /bin/cat "$WORKSPACE/FIRST-PROMPT.md"
  printf '\n%s\n' \
    "Текст сохранён в $WORKSPACE/FIRST-PROMPT.md." \
    "Следующий шаг в Терминале:" \
    "  cd \"$WORKSPACE\"" \
    "  \"$prefix/bin/claude\"" \
    "Вставь в Claude весь промпт выше."
}

apply_workspace() {
  local parent
  resolve_workspace_git || return "$?"
  if workspace_ready; then
    ui_status "Уже стоит" "$WORKSPACE"
    print_first_prompt
    open_workspace_page
    return 0
  fi
  if [ -e "$WORKSPACE" ] || [ -L "$WORKSPACE" ]; then
    ui_fail "$WORKSPACE уже существует; его содержимое не изменено."
    ui_info "Переименуй существующий каталог вручную и повтори установку."
    return 1
  fi

  parent="$HOME/dev"
  if [ -L "$parent" ] || { [ -e "$parent" ] && [ ! -d "$parent" ]; }; then
    ui_fail "$parent не является безопасным каталогом."
    return 2
  fi
  /bin/mkdir -p "$parent"
  WORKSPACE_STAGING="$(/usr/bin/mktemp -d \
    "$parent/.hello-vibe.vibe-mac.XXXXXX")"
  /bin/chmod 0700 "$WORKSPACE_STAGING"

  write_workspace_files
  workspace_git_run -C "$WORKSPACE_STAGING" init -q -b feat/first-page

  if [ -e "$WORKSPACE" ] || [ -L "$WORKSPACE" ]; then
    ui_fail "$WORKSPACE появился во время подготовки; он не изменён."
    return 1
  fi
  /bin/mv "$WORKSPACE_STAGING" "$WORKSPACE"
  WORKSPACE_STAGING=
  if is_test_mode &&
    [ "${VIBE_MAC_TEST_CRASH_AFTER_WORKSPACE_MOVE:-0}" = 1 ]; then
    return 99
  fi
  print_first_prompt
  open_workspace_page
}

trap cleanup_workspace_staging EXIT
trap 'exit 130' INT TERM HUP

case "${1:-}" in
  plan)
    ui_info "Создам локальный проект $WORKSPACE и ничего не опубликую в интернете."
    ;;
  detect|verify)
    workspace_ready
    ;;
  apply)
    apply_workspace
    ;;
  *)
    ui_fail "90-workspace: неизвестное действие."
    exit 2
    ;;
esac
