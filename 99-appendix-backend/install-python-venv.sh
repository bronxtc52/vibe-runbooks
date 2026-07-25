#!/usr/bin/env bash
# ============================================================================
# install-python-venv.sh — [ПО ТРЕБОВАНИЮ] чистая «кухня» для бэкенда (Фаза 2).
#
# ⚠️ ЭТО НЕ ЧАСТЬ ПЕРВОГО МАРШРУТА (Фазы 0). Запускать ТОЛЬКО когда дойдёшь до
#    Фазы 2 курса (урок 2.2). Для первой победы это не нужно.
#
# ЧТО ДЕЛАЕТ: в ТЕКУЩЕЙ папке проекта создаёт виртуальное окружение .venv,
#   активирует его и ставит три пакета Фазы 2: fastapi[standard],
#   pydantic-settings, asyncpg; фиксирует список в requirements.txt.
# ЧТО МЕНЯЕТ НА МАШИНЕ: создаёт папку .venv и requirements.txt в текущей папке.
#   Системный Python не трогает.
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: нет.   СКОЛЬКО ВРЕМЕНИ: 2–5 минут.
#
# Идемпотентно: если .venv уже есть — переиспользует его.
# Источник (урок 2.2): https://docs.python.org/3/library/venv.html
#                      https://fastapi.tiangolo.com/deployment/manually/
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

require_macos

step "Python для бэкенда (по требованию, Фаза 2)"
note "Запускай это ВНУТРИ папки своего серверного проекта."
note "Текущая папка: $(pwd)"
if ! ask_yes_no "Создать .venv и поставить пакеты Фазы 2 прямо здесь?"; then
  note "Отменил. Перейди в папку проекта (cd …) и запусти снова, когда будешь готов."
  exit 0
fi

# Python3 на macOS обычно приходит с Command Line Tools. Подстрахуемся.
if ! has_cmd python3; then
  warn "python3 не найден. Поставлю через Homebrew."
  ensure_brew_in_path
  if has_cmd brew; then brew install python; else err "Нет Homebrew — пройди 02-foundation/."; exit 1; fi
fi
ok "Python: $(python3 --version)"

step "Шаг 1. Чистая полка — виртуальное окружение"
if [ -d ".venv" ]; then
  ok "Папка .venv уже есть — переиспользую."
else
  log "Создаю .venv — отдельную чистую полку для инструментов этого проекта."
  python3 -m venv .venv
fi

step "Шаг 2. Активировать окружение и поставить пакеты"
# shellcheck disable=SC1091
source .venv/bin/activate
log "Активировано окружение (в строке Терминала появляется (.venv))."
log "Ставлю три пакета Фазы 2: fastapi[standard], pydantic-settings, asyncpg."
pip install --upgrade pip >/dev/null 2>&1 || true
pip install "fastapi[standard]" pydantic-settings asyncpg

step "Шаг 3. Список покупок для деплоя — requirements.txt"
pip freeze > requirements.txt
ok "Создан requirements.txt ($(wc -l < requirements.txt | tr -d ' ') строк)."

step "Проверка"
if grep -qi '^fastapi' requirements.txt && grep -qi '^pydantic-settings' requirements.txt && grep -qi '^asyncpg' requirements.txt; then
  ok "Все три пакета на месте. Кухня готова."
  note "Не коммить .venv в GitHub — добавь её в .gitignore. requirements.txt коммить нужно."
  note "Готово. Вернись в урок курса (2.2), из которого ты сюда пришёл, и продолжай по нему."
else
  warn "Не все пакеты видны в requirements.txt — проверь вывод выше."
fi
