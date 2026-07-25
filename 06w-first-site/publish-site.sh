#!/usr/bin/env bash
# ============================================================================
# publish-site.sh — сохранить сайт в GitHub и опубликовать его на Netlify.
#
# ЧТО ДЕЛАЕТ (главный ритм веб-разработки, шаг за шагом):
#   1) включает Git в проекте и делает первый снимок (если ещё нет);
#   2) показывает git status/diff и коммитит правку;
#   3) с твоего согласия создаёт ПРИВАТНЫЙ репозиторий на GitHub и пушит;
#   4) с твоего согласия публикует сайт на Netlify (netlify deploy --prod)
#      и показывает ЖИВУЮ ссылку.
# ЧТО МЕНЯЕТ НА МАШИНЕ: коммиты в проекте; наружу — репозиторий GitHub и сайт
#   на Netlify, ОБА шага только после явного подтверждения.
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: нет. Нужны вход в GitHub (фаза 03) и Netlify (фаза 05w).
# СКОЛЬКО ВРЕМЕНИ: 3–5 минут.
#
# Идемпотентно: повторный запуск безопасен — «нечего коммитить» не ошибка,
# повторный deploy просто выкатит свежую версию.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

require_macos
ensure_brew_in_path
SITE_DIR="$HOME/vibecoding/vibecoding_first_site"
REPO_NAME="vibecoding-first-site"

if [ ! -f "$SITE_DIR/index.html" ]; then
  err "Сайт не найден: $SITE_DIR. Сначала запусти 06w-first-site/create-site.sh"
  exit 1
fi
cd "$SITE_DIR"
if ! has_cmd git; then err "Git не найден. Вернись в 03-git-github/."; exit 1; fi

# Предохранитель: не пускаем секретные файлы в коммит (как в мобильной фазе 06).
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
if [ ! -f .gitignore ]; then
  printf '.env\n.netlify/\n' > .gitignore
  ok "Создал .gitignore: секреты (.env) и служебная папка Netlify в GitHub не поедут."
fi

step "Шаг 2. Посмотреть, что изменилось, и сохранить снимок"
log "Состояние файлов (git status):"
git status --short || true
log "Построчные изменения (git diff). Проверь глазами: ИИ трогал только то, что ты просил."
git --no-pager diff || true
git add -A
assert_no_secrets_staged
if git diff --cached --quiet; then
  ok "Новых изменений нет — всё уже сохранено. Это нормально."
else
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git commit -m "feat: update first site"
  else
    git commit -m "chore: initial site"
  fi
  ok "Коммит создан: $(git log -1 --pretty='%s')"
fi

step "Шаг 3. Отправить сайт в GitHub (облачный сейф)"
if git remote get-url origin >/dev/null 2>&1; then
  log "Удалённый репозиторий уже привязан — просто отправляю изменения."
  git push -u origin main || warn "Push не прошёл. Проверь вход: gh auth status"
else
  if has_cmd gh && gh auth status >/dev/null 2>&1; then
    pause_for_human "Сейчас создам ПРИВАТНЫЙ репозиторий «$REPO_NAME» на твоём GitHub и отправлю туда сайт. Это безопасно и обратимо. Продолжаем?"
    if gh repo create "$REPO_NAME" --private --source=. --remote=origin --push; then
      ok "Готово — сайт в облачном сейфе GitHub."
    else
      warn "Не удалось создать репозиторий. Проверь вход: gh auth status, и попробуй снова."
    fi
  else
    warn "Ты не вошёл в GitHub (gh). Вернись в 03-git-github/ и выполни вход, потом запусти скрипт снова."
  fi
fi

step "Шаг 4. Опубликовать сайт в интернете (Netlify)"
if ! has_cmd netlify; then
  err "Netlify CLI не найден. Сначала пройди фазу 05w: bash 05w-netlify/install-netlify.sh"
  exit 1
fi
warn "ПУБЛИКАЦИЯ: после этого шага сайт станет виден ВСЕМУ интернету по ссылке."
note "Это обратимо: сайт можно обновить новым деплоем или удалить в панели Netlify."
if ask_yes_no "Публикуем сайт на Netlify прямо сейчас?"; then
  if [ ! -f .netlify/state.json ]; then
    note "Netlify спросит пару вопросов. Отвечай так:"
    note "  «What would you like to do?» → Create & configure a new project"
    note "  team — оставь как есть (Enter); имя сайта — можно пропустить (Enter)."
  fi
  log "Публикую: netlify deploy --prod --dir ."
  netlify deploy --prod --dir .
  ok "🎉 ГЛАВНАЯ ПОБЕДА: твой сайт живёт в интернете!"
  note "Ссылка (Website URL) — в выводе выше. Открой её на телефоне и отправь другу."
  mark_step "06w-first-site:published"
else
  warn "Хорошо, не публикуем. Когда будешь готов — запусти этот скрипт снова."
fi

step "Проверка"
ok "Чек-лист первой веб-петли:"
note "• git log показывает коммит(ы) сайта;"
note "• на GitHub появился репозиторий $REPO_NAME (если шаг 3 прошёл);"
note "• сайт открывается по ссылке Netlify (если шаг 4 прошёл)."
mark_step "06w-first-site:committed"

step "Что дальше"
note "Следующий шаг — проверка фазы:  bash 06w-first-site/verify.sh"
note "Когда она зелёная — финал маршрута, общий чек-поинт:"
note "  bash 07-checkpoint/self-check.sh"
