#!/usr/bin/env bash
# ============================================================================
# setup-secret-guard.sh — защита от утечки секретов в GitHub (фаза 03).
#
# ЧТО ДЕЛАЕТ:
#   1) ставит gitleaks (сторож, который ищет ключи/пароли);
#   2) прописывает глобальный список секретных файлов, которые никогда не уходят
#      в git (.env, ключи и т.п.);
#   3) ставит глобальный pre-commit хук: перед каждым коммитом ищет секреты и
#      останавливает коммит, если что-то похожее на ключ/токен/пароль попало
#      в изменения.
# ЧТО МЕНЯЕТ НА МАШИНЕ: устанавливает gitleaks; создаёт ~/.config/git/ignore и
#   ~/.git-hooks/pre-commit; задаёт git config --global core.excludesfile и
#   core.hooksPath. Ничего не удаляет.
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: нет (Homebrew ставит без sudo).
# СКОЛЬКО ВРЕМЕНИ: до пары минут (установка gitleaks).
# ИДЕМПОТЕНТНО: да — повторный запуск безопасен, дублей не создаёт.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

require_macos
ensure_brew_in_path

step "Защита от утечки секретов в GitHub"
note "Секрет — это ключ, токен или пароль. В GitHub они попадать не должны:"
note "репозиторий видят другие, и утёкший ключ придётся срочно менять."

# ----- 1. gitleaks -----------------------------------------------------------
if has_cmd gitleaks; then
  ok "Сторож секретов уже стоит: gitleaks $(gitleaks version 2>/dev/null || echo '?')."
else
  if has_cmd brew; then
    log "Ставлю gitleaks — он проверяет изменения перед отправкой в GitHub."
    brew install gitleaks
    ok "gitleaks установлен."
  else
    err "Нет Homebrew. Сначала пройди фазу 02 (02-foundation/install-homebrew.sh)."
    exit 1
  fi
fi

# ----- 2. глобальный список секретных файлов --------------------------------
GIT_IGNORE_DIR="$HOME/.config/git"
GLOBAL_IGNORE="$GIT_IGNORE_DIR/ignore"
mkdir -p "$GIT_IGNORE_DIR"
log "Прописываю файлы, которые никогда не должны попасть в git — во всех проектах."
# armanda.txt — служебный файл курса с личными заметками ученика (может содержать
# ключи/пароли, записанные «для памяти»), поэтому тоже в глобальном игноре.
for pat in \
  ".env" ".env.*" "*.key" "*.pem" "*.p8" "*.p12" "*.keystore" \
  "id_rsa" "id_ed25519" "credentials.json" "secrets.json" "armanda.txt"; do
  append_line_once "$GLOBAL_IGNORE" "$pat"
done
git config --global core.excludesfile "$GLOBAL_IGNORE"
ok "Секретные файлы теперь игнорируются во всех твоих проектах."

# ----- 3. глобальный pre-commit хук -----------------------------------------
HOOKS_DIR="$HOME/.git-hooks"
mkdir -p "$HOOKS_DIR"
HOOK="$HOOKS_DIR/pre-commit"
cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Глобальный pre-commit: не пускать секреты в коммит + передать управление
# локальному хуку проекта, если он есть (иначе core.hooksPath его бы отключил).
# Поставлен vibe-runbooks (фаза 03). Блокирует коммит ТОЛЬКО когда gitleaks
# уверенно нашёл утечку (код 1); при ошибке инструмента — пропускает с
# предупреждением, чтобы не мешать работать.
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks help git >/dev/null 2>&1; then
    # gitleaks ≥ 8.19 — актуальная команда (protect объявлена deprecated)
    gitleaks git --pre-commit --staged --redact --no-banner >/dev/null 2>&1
  else
    gitleaks protect --staged --redact --no-banner >/dev/null 2>&1
  fi
  code=$?
  if [ "$code" -eq 1 ]; then
    echo ""
    echo "❌ СТОП: похоже, в коммит попал секрет (ключ, токен или пароль)."
    echo "   Секреты в GitHub не отправляем — это опасно."
    echo "   Что делать: убери секрет из файла; если он нужен приложению —"
    echo "   положи его в файл .env (он уже игнорируется). Подробнее в TROUBLESHOOTING.md."
    echo "   Не уверен, что это секрет? Покажи это сообщение Claude Code."
    exit 1
  elif [ "$code" -gt 1 ]; then
    echo "⚠️  Сторож секретов не смог проверить коммит (код $code) — пропускаю проверку."
  fi
fi

# Не отключаем локальные хуки проекта: если у репозитория есть свой
# .git/hooks/pre-commit — передаём ему управление.
GIT_DIR_PATH="$(git rev-parse --git-dir 2>/dev/null || true)"
if [ -n "$GIT_DIR_PATH" ] && [ -x "$GIT_DIR_PATH/hooks/pre-commit" ]; then
  exec "$GIT_DIR_PATH/hooks/pre-commit" "$@"
fi
exit 0
HOOK_EOF
chmod +x "$HOOK"
git config --global core.hooksPath "$HOOKS_DIR"
ok "Сторож секретов включён — проверка идёт сама перед каждым коммитом."
note "Нюанс: если проект сам задаёт core.hooksPath (например, husky) — локальная"
note "настройка сильнее, и в том проекте сторож не запустится. См. TROUBLESHOOTING.md."

mark_step "03-git-github:secret-guard"
step "Готово — защита от утечки секретов включена"
note "Дальше подпись Git (setup-git-identity.sh), если ещё не сделал, и verify.sh."
