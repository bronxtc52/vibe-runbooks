# INDEX — карта runbook'а и порядок прохождения

Иди строго сверху вниз. Каждую фазу заканчивай её `verify.sh` — и только потом следующая.

> Codex ведёт саму сессию по [`RITUALS.md`](RITUALS.md): что назвать человеку в начале, как продолжить с прошлого раза, когда остановиться и как завершить встречу.

| № | Папка | Что ставим | Заканчивается на | Стоп для человека |
|---|-------|------------|------------------|-------------------|
| 0 | `00-preflight/`   | ничего (осмотр) | карта: чип, macOS, что уже стоит | — |
| 1 | `01-macbook-setup/` | настройка Mac (Finder, сон, клавиатура, безопасность, Dock) | `🎉 MacBook настроен` | пароль Mac (sudo); FileVault — вручную |
| 2 | `02-foundation/`  | Command Line Tools, **Homebrew**, `tree` | `brew --version`, `tree --version` | пароль Mac; окно CLT |
| 3 | `03-git-github/`  | **Git**, **GitHub CLI**, подпись Git, **сторож секретов**, **сторож команд** | `gh auth status` = вошёл, оба сторожа включены | вход в GitHub (браузер) |
| 4 | `04-ai-helpers/`  | **Node/npm**, **Claude Code**, **Codex** | `claude` и `codex` запускаются | вход в Claude/ChatGPT |
| 5 | `05-flutter/` ⭐ мобильный трек, по желанию | **Flutter**, **Xcode**, **Android Studio**, **CocoaPods** | `flutter doctor` выдаёт карту | App Store (Xcode); пароль Mac (sudo); Setup Wizard |
| 6 | `06-first-win/` (нужна фаза 5) | учебное приложение + первый коммит | **счётчик на симуляторе** + push в GitHub | вход в GitHub уже есть |
| 5w | `05w-netlify/` ⭐ веб-трек, по желанию | **Netlify CLI** + вход | `netlify status` = вошёл | вход в Netlify (браузер) |
| 6w | `06w-first-site/` (нужна фаза 5w) | первый сайт + AGENTS.md + публикация | **сайт по живой ссылке** + push в GitHub | публикация — по «да» |
| 7 | `07-checkpoint/`  | ничего (самопроверка) | порог по трекам: 5/6, 8/10 или 11/14 → Фаза 1 курса | — |
| 99 | `99-appendix-backend/` | Python/venv, Railway | **по требованию** (Фаза 2), НЕ сейчас | — |

> ⭐ **После фазы 4 — развилка треков (по желанию, гид предлагает — см. FOR-CODEX.md):**
> **мобильный** (5 → 6: Flutter, долго, App Store) и/или **веб** (5w → 6w: Netlify, быстро,
> сайт по живой ссылке). Можно выбрать один, оба или ни одного. Отказ от Flutter фиксируется
> кнопкой `05-flutter/skip.sh` (пропускает и фазу 6). Чек-поинт 07 сам собирает чек-лист по
> выбранным трекам: только база — 5 из 6; база + трек — 8 из 10; всё — 11 из 14.
> Передумал позже — просто запусти скрипты нужного трека: пропуск установке не мешает.

## Порядок команд (шпаргалка)

```bash
# Фаза 0 — проверка машины
bash 00-preflight/check-system.sh

# Фаза 1 — настройка MacBook
bash 01-macbook-setup/setup-mac-defaults.sh
bash 01-macbook-setup/verify.sh
# bash 01-macbook-setup/install-extra-apps.sh   # по желанию, после Homebrew (фаза 2)

# Фаза 2 — фундамент
bash 02-foundation/install-homebrew.sh
bash 02-foundation/install-tree.sh
bash 02-foundation/verify.sh

# Фаза 3 — Git и GitHub
bash 03-git-github/install-git.sh
bash 03-git-github/install-gh.sh
bash 03-git-github/setup-git-identity.sh
bash 03-git-github/setup-secret-guard.sh    # сторож секретов (общий для всех проектов)
bash 03-git-github/setup-command-guard.sh   # сторож команд (блок опасных команд агента)
bash 03-git-github/verify.sh

# Фаза 4 — ИИ-помощники
bash 04-ai-helpers/install-node.sh
bash 04-ai-helpers/install-claude.sh
bash 04-ai-helpers/install-codex.sh
bash 04-ai-helpers/verify.sh

# ── Развилка треков (по желанию; гид сначала предлагает) ──

# Фаза 5 — МОБИЛЬНЫЙ трек: Flutter и мобильные цеха (отказ ↓)
# bash 05-flutter/skip.sh                    # человек отказался → пропуск 5 и 6
bash 05-flutter/install-flutter.sh
bash 05-flutter/install-xcode-tools.sh
bash 05-flutter/install-android-studio.sh
bash 05-flutter/install-cocoapods.sh
bash 05-flutter/verify.sh

# Фаза 6 — первая победа мобильного трека
bash 06-first-win/create-and-run.sh        # запускает приложение (нажми q, чтобы выйти)
# … затем правка через claude и hot reload (r) — см. 06-first-win/runbook.md …
bash 06-first-win/first-edit-commit.sh
bash 06-first-win/verify.sh

# Фаза 5w — ВЕБ-трек: Netlify (издательство сайтов)
bash 05w-netlify/install-netlify.sh
bash 05w-netlify/verify.sh

# Фаза 6w — первая победа веб-трека: сайт по живой ссылке
bash 06w-first-site/create-site.sh         # сайт + AGENTS.md, открывается в браузере
# … затем правка через codex/claude — см. 06w-first-site/runbook.md …
bash 06w-first-site/publish-site.sh        # коммит → GitHub → Netlify (по «да»)
bash 06w-first-site/verify.sh

# Фаза 7 — чек-поинт
bash 07-checkpoint/self-check.sh
```

> Все команды запускаются из корня `vibe-runbooks/`. Каждый шаг подробно описан в `runbook.md` своей папки — Codex проговаривает их новичку простым языком.

## После чек-поинта — маршрут закончен, дальше LMS
Успешный `self-check.sh` — это **конец этого runbook'а**. Фазы 1 в этом репозитории нет:
сам курс живёт в онлайн-школе — **https://academy.adarasoft.com/course/vibecoding**
(урок 1.1 «Режим плана»; проходится в `~/vibecoding/vibecoding_first_app`, если был
мобильный трек, — иначе рабочую папку подскажет сам урок).
Гид передаёт человека туда по «Контракту завершения» из `FOR-CODEX.md` и больше
не ведёт по INDEX. Папка `99-appendix-backend/` — не продолжение маршрута, а заготовка
«по требованию» для будущих фаз курса.

## Если прервались
Прогресс — в `state/progress.json` (Codex его ведёт) и `state/progress.log` (маркеры от скриптов). Можно вернуться к любой фазе и продолжить: скрипты идемпотентны, повторный запуск безопасен.

Ошибки — в `TROUBLESHOOTING.md`.
