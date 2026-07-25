#!/usr/bin/env bash
# ============================================================================
# first-edit-commit.sh — сохранить первую правку коммитом и отправить в GitHub.
#
# ВАЖНО: саму правку текста делает ИИ-помощник (claude/codex) по твоему промпту —
#   это интерактивный шаг из runbook.md, НЕ этот скрипт. Скрипт берёт на себя
#   «машину времени»: показать изменения, сделать аккуратные коммиты и отправить
#   проект в облачный сейф.
#
# ЧТО ДЕЛАЕТ:
#   1) включает Git в проекте (git init / ветка main) — если ещё не включён;
#   2) если коммитов ещё нет — делает ПЕРВЫЙ снимок ВСЕГО проекта
#      («chore: initial flutter scaffold»). Без этого в GitHub уехал бы
#      «проект» из одного файла: flutter create сам git не включает;
#   3) показывает git status и git diff (что именно изменилось);
#   4) делает атомарный коммит правки lib/main.dart;
#   5) отправляет проект в GitHub (gh repo create … --push) или git push.
# ЧТО МЕНЯЕТ НА МАШИНЕ: создаёт коммиты в локальном репозитории; создаёт
#   приватный репозиторий на GitHub и пушит в него (с твоего согласия).
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: нет. Нужен вход в GitHub (уже сделан в фазе 03).
# СКОЛЬКО ВРЕМЕНИ: 3–5 минут.
#
# Идемпотентно: повторный запуск не плодит мусор; «нечего коммитить» — не ошибка.
# Источник: https://cli.github.com/manual/gh_repo_create
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

require_macos
APP_DIR="$HOME/vibecoding/vibecoding_first_app"
if [ ! -f "$APP_DIR/pubspec.yaml" ]; then
  err "Проект не найден: $APP_DIR. Сначала запусти 06-first-win/create-and-run.sh"
  exit 1
fi
cd "$APP_DIR"
if ! has_cmd git; then err "Git не найден. Вернись в 03-git-github/."; exit 1; fi

REPO_NAME="vibecoding-first-app"

# Предохранитель: не пускаем секретные файлы в коммит. Проверяем именно то,
# что реально попадёт в коммит (staged-файлы), а не строки git status —
# прежний вариант не ловил корневой .env (перед именем в status стоит пробел).
SECRET_FILE_RE='(^|/)\.env($|\.)|\.(key|pem|p8|p12|keystore)$|(^|/)id_(rsa|ed25519)$'
assert_no_secrets_staged() {
  if git diff --cached --name-only | grep -qE "$SECRET_FILE_RE"; then
    err "В коммит попали файлы, похожие на секреты — останавливаюсь:"
    git diff --cached --name-only | grep -E "$SECRET_FILE_RE" | sed 's/^/   • /'
    note "Убери их из коммита:  git restore --staged <файл>"
    note "и добавь в .gitignore. Секреты храним в .env — он в GitHub не уходит."
    exit 1
  fi
}

step "Шаг 1. Включить машину времени Git в проекте"
if [ -d .git ]; then
  ok "Git уже включён в этом проекте."
else
  log "Включаю Git и называю основную ветку main."
  git init
  git branch -M main
fi

step "Шаг 2. Первый снимок всего проекта (если его ещё нет)"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  ok "Первый снимок уже есть — пропускаю."
else
  log "Кладу в первый коммит ВЕСЬ проект — лишнее отсеет .gitignore, созданный Flutter."
  git add -A
  assert_no_secrets_staged
  if git diff --cached --quiet; then
    warn "Добавлять нечего — в папке нет файлов для Git."
  else
    git commit -m "chore: initial flutter scaffold"
    ok "Первый снимок создан: под Git теперь $(git ls-files | wc -l | tr -d ' ') файлов проекта."
  fi
fi

step "Шаг 3. Посмотреть, что изменилось"
log "Состояние файлов (git status):"
git status --short || true
note ""
log "Построчные изменения (git diff). Проверь глазами: ИИ трогал только то, что ты просил."
git --no-pager diff || true

step "Шаг 4. Атомарный коммит правки"
# Добавляем именно правленый файл урока (а не всё подряд).
if [ -f lib/main.dart ]; then
  git add lib/main.dart
fi
assert_no_secrets_staged
# Если правок нет — это не ошибка, просто сообщаем.
if git diff --cached --quiet; then
  warn "Нечего коммитить: новых изменений в lib/main.dart нет."
  note "Либо правка уже попала в первый снимок (это нормально), либо её ещё не было —"
  note "тогда попроси Claude Code/Codex сделать правку (runbook.md, Шаг 2) и запусти скрипт снова."
else
  git commit -m "feat: update first app text"
  ok "Коммит правки создан."
fi

step "Шаг 5. Отправить проект в GitHub (облачный сейф)"
if git remote get-url origin >/dev/null 2>&1; then
  log "Удалённый репозиторий уже привязан — просто отправляю изменения."
  git push -u origin main || warn "Push не прошёл. Проверь вход: gh auth status"
else
  if has_cmd gh && gh auth status >/dev/null 2>&1; then
    pause_for_human "Сейчас создам ПРИВАТНЫЙ репозиторий «$REPO_NAME» на твоём GitHub и отправлю туда проект. Это безопасно и обратимо. Продолжаем?"
    if gh repo create "$REPO_NAME" --private --source=. --remote=origin --push; then
      ok "Готово — проект в облачном сейфе."
    else
      warn "Не удалось создать репозиторий. Проверь вход: gh auth status, и попробуй снова."
    fi
  else
    warn "Ты не вошёл в GitHub (gh). Вернись в 03-git-github/ и выполни вход, потом запусти скрипт снова."
  fi
fi

step "Проверка"
ok "Чек-лист первой петли:"
note "• под Git весь проект:  git ls-files | wc -l  — должно быть заметно больше 20;"
note "• git diff показал только нужную правку;"
note "• коммит создан (git log покажет «feat: update first app text»);"
note "• на GitHub появился репозиторий $REPO_NAME (если шаг 5 прошёл)."
mark_step "06-first-win:committed"

step "Что дальше"
note "Следующий шаг — проверка фазы:  bash 06-first-win/verify.sh"
note "Когда она зелёная — финал маршрута, общий чек-поинт (фаза 07):"
note "  bash 07-checkpoint/self-check.sh"
