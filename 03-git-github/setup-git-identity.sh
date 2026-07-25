#!/usr/bin/env bash
# ============================================================================
# setup-git-identity.sh — подписать снимки Git твоим именем и email.
#
# ЧТО ДЕЛАЕТ: задаёт git config --global user.name и user.email — это «подпись»
#   на каждом снимке проекта. Данные берёт из твоего ввода (или из переменных
#   окружения GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL, если заданы).
# ЧТО МЕНЯЕТ НА МАШИНЕ: пишет имя и email в ~/.gitconfig (это не секрет).
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: нет.   СКОЛЬКО ВРЕМЕНИ: 1 минута.
#
# Идемпотентно: если подпись уже задана — покажет её и не будет перезаписывать
# без твоего согласия. Никаких паролей/токенов здесь нет и быть не должно.
# Источник: https://git-scm.com/book/en/v2/Getting-Started-First-Time-Git-Setup
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

require_macos
if ! has_cmd git; then
  err "Git не найден. Сначала запусти 03-git-github/install-git.sh"
  exit 1
fi

step "Подпись Git (имя + email для истории проекта)"

CUR_NAME="$(git config --global user.name  || true)"
CUR_EMAIL="$(git config --global user.email || true)"

if [ -n "$CUR_NAME" ] && [ -n "$CUR_EMAIL" ]; then
  ok "Подпись уже задана:"
  note "Имя:   $CUR_NAME"
  note "Email: $CUR_EMAIL"
  if ! ask_yes_no "Поменять подпись?"; then
    note "Оставляю как есть."
    mark_step "03-git-github:identity"
    exit 0
  fi
fi

# Имя: из переменной окружения или спросить.
NAME="${GIT_AUTHOR_NAME:-}"
if [ -z "$NAME" ]; then
  if [ -t 0 ]; then
    printf '✍️  Как тебя подписывать в истории проекта (имя)? '
    read -r NAME
  fi
fi
# Email: из переменной окружения или спросить.
EMAIL="${GIT_AUTHOR_EMAIL:-}"
if [ -z "$EMAIL" ]; then
  if [ -t 0 ]; then
    printf '✍️  Твой email (лучше тот же, что на GitHub)? '
    read -r EMAIL
  fi
fi

if [ -z "$NAME" ] || [ -z "$EMAIL" ]; then
  err "Имя или email не заданы. Запусти скрипт в интерактивном режиме или передай через переменные:"
  note 'GIT_AUTHOR_NAME="Имя Фамилия" GIT_AUTHOR_EMAIL="you@example.com" bash 03-git-github/setup-git-identity.sh'
  exit 1
fi

git config --global user.name  "$NAME"
git config --global user.email "$EMAIL"

step "Проверка"
ok "Готово. Теперь Git подписывает снимки так:"
note "Имя:   $(git config --global user.name)"
note "Email: $(git config --global user.email)"
note "Дальше — сторож секретов: bash 03-git-github/setup-secret-guard.sh"
mark_step "03-git-github:identity"
