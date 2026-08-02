#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VIBE_MAC_ROOT="${VIBE_MAC_ROOT:-$(cd "$STEP_DIR/.." && pwd -P)}"
export VIBE_MAC_ROOT

# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"

WORKSPACE="$HOME/dev/hello-vibe"
WORKSPACE_STAGING=

workspace_ready() {
  local branch remote
  [ -d "$WORKSPACE" ] || return 1
  [ ! -L "$WORKSPACE" ] || return 1
  [ -f "$WORKSPACE/index.html" ] || return 1
  [ -f "$WORKSPACE/AGENTS.md" ] || return 1
  [ -f "$WORKSPACE/CLAUDE.md" ] || return 1
  [ -f "$WORKSPACE/FIRST-PROMPT.md" ] || return 1
  [ -f "$WORKSPACE/.mise.toml" ] || return 1
  [ -d "$WORKSPACE/.git" ] || return 1
  branch="$(git -C "$WORKSPACE" branch --show-current 2>/dev/null)" ||
    return 1
  [ "$branch" = "feat/first-page" ] || return 1
  remote="$(git -C "$WORKSPACE" remote 2>/dev/null)" || return 1
  [ -z "$remote" ] || return 1
  # The backticks below are literal Markdown.
  # shellcheck disable=SC2016
  /usr/bin/grep -Fq 'менять только `index.html`' \
    "$WORKSPACE/FIRST-PROMPT.md" || return 1
  /usr/bin/grep -Fq 'не публикуй' \
    "$WORKSPACE/FIRST-PROMPT.md" || return 1
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

  /bin/cat >"$WORKSPACE_STAGING/FIRST-PROMPT.md" <<'PROMPT'
# Первый промпт для Claude

Открой проект в текущей папке и улучши стартовую страницу.

Правила этой первой задачи:

- можно менять только `index.html`;
- сделай одну аккуратную HTML-страницу без внешних зависимостей;
- не трогай остальные файлы;
- не создавай commit, remote или репозиторий GitHub;
- не публикуй и не деплой результат;
- перед изменением коротко объясни план, затем проверь страницу локально.
PROMPT
}

open_workspace_page() {
  local open_bin
  if ! ui_pause "Проект готов. Сейчас открою локальную страницу в системном браузере."; then
    ui_warn "Страница не открыта автоматически. Файлы проекта уже готовы."
    return 0
  fi
  if is_test_mode; then
    open_bin="${VIBE_MAC_OPEN_BIN:?test open не задан}"
  else
    open_bin=/usr/bin/open
  fi
  "$open_bin" "$WORKSPACE/index.html"
}

apply_workspace() {
  local parent
  if workspace_ready; then
    ui_status "Уже стоит" "$WORKSPACE"
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
  git -C "$WORKSPACE_STAGING" init -q -b feat/first-page

  if [ -e "$WORKSPACE" ] || [ -L "$WORKSPACE" ]; then
    ui_fail "$WORKSPACE появился во время подготовки; он не изменён."
    return 1
  fi
  /bin/mv "$WORKSPACE_STAGING" "$WORKSPACE"
  WORKSPACE_STAGING=
  open_workspace_page
}

trap cleanup_workspace_staging EXIT
trap 'exit 130' INT TERM HUP

case "${1:-}" in
  plan)
    ui_info "Создам локальный проект $WORKSPACE без commit, remote, push или deploy."
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
