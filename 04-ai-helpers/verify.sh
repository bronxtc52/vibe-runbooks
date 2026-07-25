#!/usr/bin/env bash
# ============================================================================
# verify.sh — проверка фазы 04: Node, npm, Claude Code, Codex.
#
# ЧТО ДЕЛАЕТ: проверяет, что команды node, npm, claude, codex доступны.
#   Вход в аккаунты ИИ здесь НЕ проверяется (это интерактивный шаг человека).
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: нет.   СКОЛЬКО ВРЕМЕНИ: секунды.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

ensure_brew_in_path
fail=0

step "Проверка фазы 04 — ИИ-помощники"

if has_cmd node && node -v >/dev/null 2>&1; then ok "Node: $(node -v)"; else err "Node нет."; fail=1; fi
if has_cmd npm  && npm  -v >/dev/null 2>&1; then ok "npm:  $(npm -v)";  else err "npm нет.";  fail=1; fi

if has_cmd claude; then ok "Claude Code: команда claude доступна."; else err "claude не установлен."; fail=1; fi
if has_cmd codex;  then ok "Codex: команда codex доступна.";        else err "codex не установлен.";  fail=1; fi

if [ "$fail" -eq 0 ]; then
  ok "Фаза 04 пройдена. Дальше — развилка: выбирай трек по желанию."
  note "Мобильный трек (05-flutter/) и/или веб-трек (05w-netlify/) — можно один,"
  note "оба или ни одного; гид спросит, что тебе ближе. Подробности — в INDEX.md."
  note "Напоминание: при первом  claude  и  codex  будет вход в аккаунт — это нормально."
  mark_step "04-ai-helpers:verified"
else
  err "Есть незакрытые пункты. Вернись к скриптам фазы 04 или открой TROUBLESHOOTING.md."
  exit 1
fi
