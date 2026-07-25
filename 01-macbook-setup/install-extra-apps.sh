#!/usr/bin/env bash
# ============================================================================
# install-extra-apps.sh — [ПО ЖЕЛАНИЮ] удобные приложения для работы.
#
# ⚠️ НЕ ОБЯЗАТЕЛЬНО. Курс «Вайбкодинг» работает в Claude Code и Codex (это ставит
#    фаза 04-ai-helpers). Эти приложения — просто приятные дополнения, не нужны
#    для прохождения курса. Ставь, только если хочешь.
#
# ЧТО ДЕЛАЕТ: ставит через Homebrew удобные программы: Cursor (AI-редактор),
#   VS Code, iTerm2, Warp, Raycast, Rectangle. Каждую — только если её ещё нет.
# ЧТО МЕНЯЕТ НА МАШИНЕ: добавляет cask-приложения через Homebrew.
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: иногда Homebrew просит пароль для cask — это нормально.
# СКОЛЬКО ВРЕМЕНИ: 5–15 минут (зависит от того, сколько выберешь).
#
# Идемпотентно: уже установленные приложения пропускаются.
# Требует Homebrew — поставь его сначала (фаза 02-foundation).
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

require_macos
ensure_brew_in_path
if ! has_cmd brew; then
  warn "Homebrew ещё не установлен — а он нужен для этих приложений."
  note "Сначала пройди фазу 02-foundation/ (там ставится Homebrew), потом вернись сюда."
  exit 1
fi

step "Дополнительные приложения (по желанию)"
note "Это НЕ требуется курсом. Курс работает в Claude Code и Codex."
if ! ask_yes_no "Поставить набор удобных приложений (Cursor, VS Code, iTerm2, Warp, Raycast, Rectangle)?"; then
  note "Пропускаю. Никаких дополнительных приложений не ставлю."
  exit 0
fi

# Имя каска → человеческое описание.
install_cask() { # install_cask <token> <описание>
  local token="$1" desc="$2"
  if brew_pkg_installed "$token"; then
    ok "$desc — уже установлено, пропускаю."
  else
    log "Ставлю: $desc"
    brew install --cask "$token" || warn "$desc — не удалось поставить (можно пропустить)."
  fi
}

install_cask visual-studio-code "VS Code — запасной редактор кода"
install_cask cursor             "Cursor — AI-редактор кода"
install_cask iterm2             "iTerm2 — улучшенный Терминал"
install_cask warp               "Warp — современный Терминал с ИИ"
install_cask raycast            "Raycast — быстрый запуск (замена Spotlight)"
install_cask rectangle          "Rectangle — управление окнами с клавиатуры"

step "Готово"
ok "Дополнительные приложения обработаны."
note "Cursor/VS Code открываются через Spotlight (Cmd+Пробел → имя). Вход — через Google или GitHub."
note "Для курса они не обязательны: основная работа идёт в claude и codex."
note "Это побочный квест — вернись в ту фазу, где остановился (см. INDEX.md)."
mark_step "01-macbook-setup:extra-apps"
