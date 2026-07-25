#!/usr/bin/env bash
# ============================================================================
# self-check.sh — финальная самопроверка всей Фазы 0.
#
# ЧТО ДЕЛАЕТ: проходит по всему чек-листу готовности к Фазе 1 курса и считает,
#   сколько пунктов выполнено. Ничего не устанавливает.
# ЧТО МЕНЯЕТ НА МАШИНЕ: ничего (только проверка).
# НУЖЕН ЛИ ПАРОЛЬ/SUDO: нет.   СКОЛЬКО ВРЕМЕНИ: 1–2 минуты (flutter doctor).
#
# Чек-лист собирается из блоков по выбранным трекам:
#   база (6 пунктов) — всегда;
#   мобильный трек (4) — если Flutter не пропущен через 05-flutter/skip.sh;
#   веб-трек (4) — если начата фаза 05w (Netlify) или создан учебный сайт.
# Порог ~80%: только база — 5 из 6; база+один трек — 8 из 10; всё — 11 из 14.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

ensure_brew_in_path
APP_DIR="$HOME/vibecoding/vibecoding_first_app"
SITE_DIR="$HOME/vibecoding/vibecoding_first_site"
PROGRESS_LOG="$SCRIPT_DIR/../state/progress.log"

# Пропущен ли Flutter по выбору человека? Маркер ставит 05-flutter/skip.sh.
# Если Flutter потом всё же поставили — маркер игнорируем и считаем полный список.
flutter_skipped=0
if grep -Fqx "05-flutter:skipped" "$PROGRESS_LOG" 2>/dev/null \
   && ! has_cmd flutter; then
  flutter_skipped=1
fi

# Выбран ли веб-трек? Маркер ставит 05w-netlify/install-netlify.sh;
# подстраховка — существующий учебный сайт.
web_track=0
if grep -Fqx "05w-netlify:installed" "$PROGRESS_LOG" 2>/dev/null \
   || [ -f "$SITE_DIR/index.html" ]; then
  web_track=1
fi

pass=0; total=6
[ "$flutter_skipped" = "0" ] && total=$((total+4))
[ "$web_track" = "1" ]       && total=$((total+4))
case "$total" in
  6)  threshold=5 ;;
  10) threshold=8 ;;
  *)  threshold=11 ;;
esac

check() { # check "описание" <команда-проверки...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
    pass=$((pass+1))
  else
    warn "ещё нет — $desc"
  fi
}

step "Чек-поинт Фазы 0 — рабочее место режиссёра"

check "Homebrew работает (brew --version)"        bash -c 'brew --version'
check "Git работает (git --version)"              bash -c 'git --version'
check "Вход в GitHub (gh auth status)"            bash -c 'gh auth status'
check "Node и npm работают"                        bash -c 'node -v && npm -v'
check "Claude Code доступен (claude)"              command -v claude
check "Codex доступен (codex)"                     command -v codex
if [ "$flutter_skipped" = "1" ]; then
  note "Flutter пропущен по твоему выбору — мобильные пункты (4 шт.) не считаются."
else
  check "Flutter доктор запускается (flutter doctor)" bash -c 'flutter doctor'
  check "Учебный проект существует"                  test -f "$APP_DIR/pubspec.yaml"
  check "В проекте есть коммит (весь проект под Git)" bash -c "git -C '$APP_DIR' rev-parse HEAD && [ \"\$(git -C '$APP_DIR' ls-files | wc -l)\" -gt 20 ]"
  check "Проект привязан к GitHub"                    bash -c "git -C '$APP_DIR' remote get-url origin"
fi

if [ "$web_track" = "1" ]; then
  check "Netlify CLI доступен (netlify)"              command -v netlify
  check "Учебный сайт существует"                     test -f "$SITE_DIR/index.html"
  check "В сайте есть коммит и привязка к GitHub"     bash -c "git -C '$SITE_DIR' rev-parse HEAD && git -C '$SITE_DIR' remote get-url origin"
  check "Сайт публиковался на Netlify"                test -f "$SITE_DIR/.netlify/state.json"
fi

step "Итог"
ok "Выполнено: $pass из $total пунктов."
if [ "$pass" -ge "$threshold" ]; then
  ok "🎉 Фаза 0 пройдена! Этот setup-runbook (vibe-runbooks) полностью завершён."
  mark_step "07-checkpoint:passed"

  step "Куда дальше — Фаза 1 курса (она НЕ здесь)"
  note "Материалы Фазы 1 лежат не в этом репозитории, а в онлайн-школе курса (LMS)."
  note "Здесь, в vibe-runbooks, больше ничего искать и делать не нужно."
  printf '\n'
  note "Твой следующий шаг:"
  note "1. Открой в браузере страницу курса и войди:"
  note "      https://academy.adarasoft.com/course/vibecoding"
  note "2. Открой урок 1.1 «Режим плана (Plan Mode): сначала план, потом дело»."
  if [ "$flutter_skipped" = "0" ] && [ -f "$APP_DIR/pubspec.yaml" ]; then
    note "3. Перейди в папку учебного проекта (в ней идёт весь урок):"
    note "      cd ~/vibecoding/vibecoding_first_app"
    note "4. Дальше делай строго то, что написано в уроке 1.1."
  else
    note "3. Дальше делай строго то, что написано в уроке 1.1 —"
    note "   он сам подскажет, в какой папке работать."
  fi
else
  warn "Готовность ниже порога (нужно $threshold из $total)."
  note "Не перепрыгивай. Вернись к нужной фазе runbook'а и закрой пробел."
  note "Промпт для ИИ: «Вот вывод проверочных команд. Скажи, готов ли я к Фазе 1. Если нет — дай ОДИН самый важный следующий шаг простыми словами.»"
fi

step "Чего мы НЕ делали в Фазе 0 (и это правильно)"
note "Не подключали сервер, базу данных, авторизацию, Firebase, платежи, TestFlight."
note "Это не пробелы — это защита от перегруза. Всё придёт в Фазах 2–4, когда появится нужда."
