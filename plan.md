# План полной пересборки `vibe-runbooks` в `vibe-mac`

- Статус: **approved — утверждено владельцем 2026-08-02**
- Дата: 2026-08-02
- База: `origin/main` (`4bc5da0`)
- Ветка: `codex/vibe-mac-refactor`
- Каноническое ТЗ:
  [`docs/specs/2026-08-02-vibe-mac-full-refactor.md`](docs/specs/2026-08-02-vibe-mac-full-refactor.md)
- Первая версия продукта: `0.1.0-dev`; production-тег назначается только на
  отдельном release-гейте.

## 0. Гейт утверждения

Этот документ фиксирует архитектуру и порядок реализации. До отдельного
утверждения плана разрешены только изменения самого ТЗ и `plan.md`; код
инсталлятора, старые файлы и пользовательская машина не меняются.

Утверждение плана означает также утверждение двух необходимых уточнений к ТЗ.
После утверждения они будут внесены в каноническую спецификацию первым
документальным изменением.

### A1. Минимальная версия macOS

Production-минимум меняется с **macOS 13** на **macOS 14**.

Причина: Homebrew официально поддерживает macOS 14+, а macOS 13 относится к
unsupported/Tier 3. Ghostty 1.3.1 ещё запускается на macOS 13, но это последняя
такая ветка; Ghostty 1.4 требует macOS 14. Обещать новичку надёжную установку на
Ventura нельзя. Intel остаётся отдельным unsupported opt-in независимо от
версии macOS.

### A2. Граница гарантии Homebrew

`Brewfile` не является lockfile. Для уже установленных **прямых** formula/cask
инсталлятор гарантирует отсутствие явного `upgrade`, `reinstall`, `relink`,
`cleanup` и `zap`. Он передаёт `--no-upgrade` и защитные переменные Homebrew,
пропускает внешние эквивалентные установки и сравнивает снимки до/после.

Однако Homebrew может обновить уже существующую **транзитивную зависимость**,
если без этого нельзя установить новый обязательный пакет. Скрыть или обещать
невозможность такого изменения нельзя. Оно записывается в manifest и явно
показывается в итоговом отчёте. Тест приёмки проверяет отсутствие намеренных
изменений прямых preexisting-пакетов и полный отчёт о dependency-delta, а не
невыполнимую побайтовую неизменность всей Homebrew-системы.

Плавающие formula/cask получают актуальную версию на момент установки.
Точными immutable pins остаются версия bundle `vibe-mac`, Homebrew installer,
Oh My Zsh, Node.js и Python. Фактически поставленные версии всех остальных
пакетов сохраняются в manifest и release evidence.

## 1. Результат этой итерации

В существующей Git-истории появится новый продукт `vibe-mac`:

1. одна безопасная точка входа `install.sh`;
2. проверяемый тонкий `bootstrap.sh` для будущего versioned release;
3. десять возобновляемых шагов `00`–`90`;
4. постоянный versioned bundle в `~/.vibe-mac`;
5. двенадцатипунктовый read-only verifier;
6. read-only doctor с отдельным ограниченным ремонтом;
7. ownership-aware uninstall, который по умолчанию лишь показывает план;
8. sandbox-тесты без изменений настоящего `HOME`;
9. русская документация для абсолютного новичка;
10. полное удаление старого Flutter/Android/Netlify/LMS-маршрута из рабочей
    версии репозитория.

В эту итерацию не входят rename GitHub-репозитория, merge в `main`, публикация
релиза, production-команды, реальные входы в аккаунты и полный пилот на чистом
Mac. Они остаются отдельными approval-гейтами.

## 2. Архитектура и поток управления

```text
versioned one-liner
  -> проверка SHA-256 bootstrap до исполнения
  -> bootstrap.sh
       -> проверка встроенного SHA-256 release-архива
       -> безопасная распаковка в staging
       -> ~/.vibe-mac/releases/<version>
       -> атомарный ~/.vibe-mac/current
       -> launchers в ~/.vibe-mac/bin
       -> install.sh из постоянного bundle
            -> read-only preflight
            -> lock + private log/state
            -> steps/00..90: plan -> apply -> verify
            -> progress.json + manifest.json

vibe-mac-verify ----\
vibe-mac-doctor -----+-> те же detect/verify-функции и manifest
vibe-mac-uninstall --/
```

### 2.1 Режимы запуска

- **Checkout:** `/bin/bash ./install.sh` использует файлы текущего checkout.
- **Installed bundle:** `~/.vibe-mac/current/install.sh` продолжает или
  перепроверяет установку.
- **Bootstrap:** устанавливает только проверенный versioned bundle и передаёт
  управление его `install.sh`.
- **DRY_RUN:** `DRY_RUN=1` проходит только локальные read-only detect/plan.
  До выхода запрещены mkdir/temp/log/state/lock, сеть, package managers,
  `sudo`, `defaults write`, `killall`, `open` и auth-команды.
- **Extras:** `EXTRAS=1` добавляет только `Brewfile.extras`.
- **Без defaults:** `SKIP_DEFAULTS=1` полностью исключает шаг `80`.

Все булевы переменные принимают только `0` или `1`; неизвестное значение
завершает запуск с exit `2` до записи.

### 2.2 Контракт шага

Каждый `steps/NN-name.sh` запускается отдельным `/bin/bash` и поддерживает
четыре действия:

- `plan` — только печатает, что будет сделано;
- `detect` — локально определяет текущее состояние;
- `apply` — выполняет ограниченное изменение;
- `verify` — независимо проверяет фактический результат.

Алгоритм оркестратора:

1. вызывает `verify` даже при `completed` в progress;
2. при успехе печатает `Уже стоит` и не меняет state;
3. иначе печатает `plan`, выполняет `apply`, затем тот же `verify`;
4. только после зелёного `verify` атомарно ставит `completed`;
5. при ошибке останавливается, печатает ID шага и путь к приватному логу;
6. повторный запуск начинает с первого фактически незавершённого шага.

Стабильные итоговые слова: `Установлено`, `Уже стоит`, `Пропущено`,
`Ошибка`. Exit codes `install.sh`: `0` — техническая установка завершена,
`1` — шаг не выполнен, `2` — platform/usage/integrity error.

### 2.3 Bash и зависимости раннего этапа

- Все entrypoint, библиотеки и шаги: `#!/usr/bin/env bash` и
  `set -euo pipefail`.
- Код совместим с системным Bash 3.2: без associative arrays, `mapfile`,
  `readarray`, `${var,,}`, `wait -n` и GNU-only flags.
- До шага `30` используются только встроенные средства macOS:
  `/bin/bash`, `/bin/zsh`, `/usr/bin/curl`, `/usr/bin/shasum`,
  `/usr/bin/plutil`, `/usr/bin/tar`, `/usr/bin/awk`, `/usr/bin/sed`,
  `/usr/bin/grep`, `/usr/bin/find`, `/usr/bin/stat`, `/bin/df`,
  `/bin/mkdir`, `/bin/mv`, `/bin/cp` и `/bin/chmod`.
- `jq`, Python, Node и GNU-утилиты не участвуют в раннем state.
- В тестах путь к `plutil` заменяется только через тестовый adapter; production
  default всегда `/usr/bin/plutil`.

## 3. Runtime layout и ownership

```text
~/.vibe-mac/                         mode 0700
├── releases/
│   └── <version>/                  неизменяемый bundle
├── current -> releases/<version>   атомарно сменяемая ссылка
├── bin/
│   ├── vibe-mac-verify
│   ├── vibe-mac-doctor
│   └── vibe-mac-uninstall
├── state/
│   ├── progress.json               mode 0600
│   ├── manifest.json               mode 0600
│   └── install.lock.d/             атомарный mkdir-lock
└── logs/
    └── install-<UTC timestamp>.log mode 0600

~/.vibe-mac-backup/<UTC timestamp>/ mode 0700
~/.config/vibe-mac/aliases.zsh
~/dev/hello-vibe/
```

`umask 077` устанавливается до первой runtime-записи. На unsupported OS/arch и
при `DRY_RUN=1` эти каталоги не создаются.

Lock содержит только PID, версию и время без имени пользователя. Обычный trap
снимает свой lock. Автоматически удалять чужой/сомнительный stale lock нельзя:
read-only doctor его выявляет, а `doctor --repair` удаляет только после
проверки, что PID не существует и путь является точным
`~/.vibe-mac/state/install.lock.d`.

### 3.1 `progress.json`

Шаблон имеет фиксированные ключи, чтобы не строить JSON строковой
конкатенацией:

```json
{
  "schema_version": 1,
  "installer_version": "0.1.0-dev",
  "last_run_id": "",
  "steps": {
    "00-preflight": {"status": "pending", "completed_at": ""},
    "10-xcode-clt": {"status": "pending", "completed_at": ""},
    "20-homebrew": {"status": "pending", "completed_at": ""},
    "30-brew-bundle": {"status": "pending", "completed_at": ""},
    "40-shell": {"status": "pending", "completed_at": ""},
    "50-runtimes": {"status": "pending", "completed_at": ""},
    "60-ai-agents": {"status": "pending", "completed_at": ""},
    "70-git-github": {"status": "pending", "completed_at": ""},
    "80-defaults": {"status": "pending", "completed_at": ""},
    "90-workspace": {"status": "pending", "completed_at": ""}
  }
}
```

Запись: копия в temp **в той же директории** → `plutil -replace` только
фиксированного key path → `plutil -lint` → `chmod 0600` → атомарный `mv`.
Повреждённый или неизвестный schema version завершается fail-closed и не
перезаписывается.

### 3.2 `manifest.json`

Manifest создаётся из фиксированного шаблона и хранит:

- schema/installer version, install ID, arm64/Intel и macOS version;
- formula/cask: `preexisting`, `owner`, version before/after;
- обнаруженные dependency-delta Homebrew;
- файлы: логический ID, `home_relative`/allowlisted system path, backup,
  before/applied/current SHA и managed-block SHA;
- defaults: domain/key, существовал ли ключ, исходное bool и применённое bool;
- Oh My Zsh и runtimes: source/version, preexisting/owned;
- versioned bundles и launchers.

Абсолютные пути из внешнего ввода в manifest не принимаются. Пользовательские
пути кодируются как `path_kind: home_relative` + нормализованный relative path;
`..`, пустой сегмент, newline, symlink escape и выход за allowlist блокируются.
Uninstall не доверяет manifest на слово: перед каждым действием заново
канонизирует путь и сверяет ownership/hash.

Manifest меняется тем же temp → validate → atomic mv. Данные auth, имя, email,
username, environment dump и содержимое пользовательских файлов в него не
попадают.

## 4. Точная карта репозитория

### 4.1 Создать

```text
bootstrap.sh
install.sh
verify.sh
doctor.sh
uninstall.sh
Brewfile
Brewfile.extras

lib/ui.sh
lib/guard.sh
lib/util.sh

steps/00-preflight.sh
steps/10-xcode-clt.sh
steps/20-homebrew.sh
steps/30-brew-bundle.sh
steps/40-shell.sh
steps/50-runtimes.sh
steps/60-ai-agents.sh
steps/70-git-github.sh
steps/80-defaults.sh
steps/90-workspace.sh

config/AGENTS.md
config/CLAUDE.md
config/aliases.zsh
config/ghostty.config
config/mise.toml
config/starship.toml
config/versions.env

state/manifest-template.json

scripts/check.sh
scripts/package-release.sh
scripts/secret-scan.sh

tests/helpers/assertions.bash
tests/helpers/fake-bin.bash
tests/helpers/plutil_stub.py
tests/helpers/test-helper.bash
tests/fixtures/bootstrap/good/install.sh
tests/fixtures/bootstrap/symlink-target
tests/fixtures/tripwire/bad-step.sh
tests/unit/guard.bats
tests/unit/state.bats
tests/unit/ui.bats
tests/unit/util.bats
tests/integration/auth.bats
tests/integration/bootstrap.bats
tests/integration/brew-bundle.bats
tests/integration/defaults.bats
tests/integration/doctor.bats
tests/integration/dry-run.bats
tests/integration/install.bats
tests/integration/resume.bats
tests/integration/runtimes.bats
tests/integration/shell.bats
tests/integration/uninstall.bats
tests/integration/verify.bats
tests/integration/workspace.bats
tests/policy/bash32.bats
tests/policy/brewfile.bats
tests/policy/doctrine.bats
tests/policy/legacy-removal.bats
tests/policy/secrets.bats
```

Дополнительные файлы `bootstrap.sh`, `config/versions.env`,
`config/mise.toml` и `state/manifest-template.json` прямо следуют из разделов
9–12 ТЗ и дополняют сокращённое дерево из раздела 8.

### 4.2 Переписать целиком

- `AGENTS.md` — короткий контракт разработки `vibe-mac` со ссылками на ТЗ и
  этот план; никакого автозапуска старых учебных фаз.
- `README.md` — продукт, состав, ограничения, флаги, будущий versioned quick
  start, ручные входы, verify/doctor/uninstall.
- `TROUBLESHOOTING.md` — только новая архитектура.
- `state/progress-template.json` — схема из раздела 3.1.
- `.gitignore` — только runtime/test/release artifacts нового продукта.
- `.shellcheckrc` — source-path и узкие обоснованные исключения нового дерева.
- `.github/workflows/ci.yml` — pinned actions, Ubuntu suite и macOS arm64
  read-only smoke из раздела 12.3.

### 4.3 Сохранить

- `docs/specs/2026-08-02-vibe-mac-full-refactor.md`, с двумя утверждёнными
  поправками A1/A2;
- `plan.md` как живой implementation checklist и запись решений;
- Git-историю репозитория.

### 4.4 Удалить как обратимый Git diff

```text
00-preflight/
01-macbook-setup/
02-foundation/
03-git-github/
04-ai-helpers/
05-flutter/
05w-netlify/
06-first-win/
06w-first-site/
07-checkpoint/
99-appendix-backend/

CLAUDE.md
FOR-CODEX.md
INDEX.md
RITUALS.md
templates/

scripts/askpass.sh
scripts/command-guard.py
scripts/lib.sh

tests/checkpoint-handoff.bats
tests/command-guard.bats
tests/lib.bats
tests/routing.bats
tests/secret-regex.bats
```

Удаление не запускает старые uninstall-команды и ничего не удаляет с Mac.
Корневой `CLAUDE.md` не сохраняется: рабочие правила разработчиков находятся в
`AGENTS.md`, а проектный шаблон Claude — в `config/CLAUDE.md`.

## 5. Точные package manifests

### 5.1 `Brewfile`

```ruby
brew "git"
brew "gh"
brew "starship"
brew "ripgrep"
brew "fd"
brew "fzf"
brew "bat"
brew "eza"
brew "jq"
brew "tree"
brew "zoxide"
brew "mise"
brew "uv"

cask "ghostty"
cask "font-jetbrains-mono-nerd-font"
cask "claude-code"
cask "codex"
cask "cursor"
cask "cursor-cli"
```

### 5.2 `Brewfile.extras`

```ruby
cask "zed"
cask "raycast"
cask "visual-studio-code"
```

Тест политики сравнивает manifests с exact allowlist и отдельно запрещает
Xcode.app, Flutter, Dart, CocoaPods, simulators, Android/JDK/Kotlin, JetBrains
IDE, React Native, Unity, Ruby toolchains, Go, Rust, Docker, nvm, pyenv, conda
и bun.

### 5.3 Применение Brewfile

Основной вызов:

```bash
HOMEBREW_NO_AUTO_UPDATE=1 \
HOMEBREW_NO_INSTALL_UPGRADE=1 \
HOMEBREW_NO_INSTALL_CLEANUP=1 \
HOMEBREW_BUNDLE_NO_UPGRADE=1 \
HOMEBREW_BUNDLE_BREW_SKIP="$formula_skip" \
HOMEBREW_BUNDLE_CASK_SKIP="$cask_skip" \
brew bundle install --file="$VIBE_MAC_ROOT/Brewfile" --no-upgrade
```

Для `EXTRAS=1` второй такой же вызов получает `Brewfile.extras`. Никогда не
вызываются `brew upgrade`, `brew reinstall`, `brew link --overwrite`,
`brew cleanup`, `brew bundle cleanup`, `brew uninstall --zap` или `brew pin`.
Если metadata существующего Homebrew слишком стара и установка не может идти
без `brew update`, автоматического update нет: шаг останавливается и даёт
понятную ручную диагностику.

Skip-листы строятся только из проверенных имён:

- уже установленная formula/cask Homebrew;
- точное GUI-приложение в `/Applications`, установленное не Homebrew;
- рабочий внешний CLI с распознаваемой версией и корректной архитектурой.

Снимки `brew list --formula --versions` и `brew list --cask --versions`
снимаются до/после. Прямая preexisting-позиция, изменившая версию, делает
проверку красной. Изменившаяся транзитивная зависимость становится явным
warning и записью manifest согласно A2.

## 6. Фиксация версий и источников

### 6.1 `config/versions.env`

```bash
VIBE_MAC_VERSION="0.1.0-dev"
STATE_SCHEMA_VERSION="1"
MANIFEST_SCHEMA_VERSION="1"
MIN_MACOS_MAJOR="14"
MIN_FREE_DISK_GB="15"
NODE_VERSION="24.18.1"
PYTHON_VERSION="3.12.13"
MISE_MIN_TESTED_VERSION="2026.8.0"
HOMEBREW_INSTALL_COMMIT="39a0c068274254a7658fd9761d59bce9d0e2151f"
HOMEBREW_INSTALL_SHA256="8ff338091a5e10bb5fc040b38316648110f42feff057ecf9feaab51fd0a13ef9"
OH_MY_ZSH_COMMIT="c5ba74cf02cce4c342153f79089100194f30940f"
OH_MY_ZSH_ARCHIVE_SHA256="5603797f3b29258a18151234f5be34690655ffe8714805e49808e29abcf488aa"
```

Все значения проверены 2026-08-02. Перед production release они обновляются
отдельным PR либо подтверждаются повторной сверкой первичных источников.

### 6.2 Истинные pins и tested snapshot

| Компонент | Значение | Контракт |
|---|---:|---|
| `vibe-mac` | будущий immutable version tag | точный bundle |
| Homebrew installer | commit `39a0c06…` + SHA-256 выше | точный файл |
| Oh My Zsh | commit `c5ba74c…` + SHA-256 tarball | точный архив |
| Node.js LTS | `24.18.1` | точный pin через mise |
| Python 3.12 | `3.12.13` | точный pin через mise |
| Ghostty | `1.3.1` на дату проверки | tested snapshot, cask плавающий |
| Starship | `1.26.0` | tested snapshot, formula плавающая |
| mise | `2026.8.0` | minimum/tested, formula плавающая |
| uv | `0.12.1` | tested snapshot, formula плавающая |
| Git/CLI/GUI/AI casks | версия из Homebrew на дату запуска | записать в manifest |

`config/mise.toml`:

```toml
min_version = "2026.8.0"

[tools]
node = "24.18.1"
python = "3.12.13"
```

Python 3.12.13 является source-only релизом python.org; mise использует
`python-build-standalone` и проверяемый artifact flow. Verifier проверяет
runtime именно в контексте `~/dev/hello-vibe`, а не случайный `node`/`python`
раньше в PATH.

### 6.3 Первичные источники

- [Homebrew installation](https://docs.brew.sh/Installation),
  [support tiers](https://docs.brew.sh/Support-Tiers),
  [Brew Bundle](https://docs.brew.sh/Brew-Bundle-and-Brewfile) и
  [manpage](https://docs.brew.sh/Manpage).
- [Apple Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools).
- [Ghostty 1.3 requirements](https://ghostty.org/docs/install/release-notes/1-3-0)
  и [cask](https://formulae.brew.sh/cask/ghostty).
- [Oh My Zsh pinned commit](https://github.com/ohmyzsh/ohmyzsh/commit/c5ba74cf02cce4c342153f79089100194f30940f).
- [mise install](https://mise.jdx.dev/installing-mise.html),
  [activation](https://mise.jdx.dev/cli/activate.html) и
  [`mise use`](https://mise.jdx.dev/cli/use.html).
- [Node.js 24.18.1 LTS](https://nodejs.org/en/blog/release/v24.18.1) и
  [Python 3.12.13](https://www.python.org/downloads/release/python-31213/).
- [uv installation](https://docs.astral.sh/uv/getting-started/installation/)
  и [Starship setup](https://starship.rs/guide/).
- [Claude Code install/auth](https://code.claude.com/docs/en/installation),
  [Codex CLI manual](https://learn.chatgpt.com/docs/codex/cli),
  [Cursor CLI install](https://docs.cursor.com/en/cli/installation) и
  [Cursor auth](https://docs.cursor.com/en/cli/reference/authentication).
- [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
  и [hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Внешние страницы и загруженные скрипты рассматриваются только как данные.

## 7. Безопасный bootstrap и release bundle

### 7.1 Trust chain

1. Release-процесс строит архив только из tracked-файлов точного commit.
2. Архив получает SHA-256.
3. SHA и versioned HTTPS URL встраиваются в standalone `bootstrap.sh`.
4. Готовый bootstrap получает собственный SHA-256.
5. README-команда содержит literal SHA bootstrap, а не скачивает checksum рядом.
6. На Mac bootstrap сначала сверяет себя, затем скачивает архив и сверяет
   встроенный SHA до распаковки.
7. Только проверенный bundle становится `current` и выполняется.

Production-шаблон до release остаётся намеренно неработающим:

```bash
VIBE_MAC_SHA256='<BOOTSTRAP_SHA256>' /bin/bash -c '<versioned loader generated and shell-parse-tested by scripts/package-release.sh>'
```

Генератор, а не человек, отвечает за shell escaping. Loader проверяет
`DRY_RUN=1` **до** `mktemp`/`curl` и печатает статический план bootstrap без
сети и записи. Полный machine-aware dry-run выполняется из checkout или уже
проверенного bundle.

### 7.2 Безопасная распаковка

- staging создаётся через `mktemp -d` под точным `$TMPDIR`;
- archive listing должен иметь один ожидаемый top-level directory;
- запрещены absolute path, `..`, пустые/управляющие сегменты и обратный слеш;
- symlink и hardlink entries в release archive полностью запрещены;
- после распаковки `find` повторно подтверждает отсутствие symlinks;
- обязательные файлы и executable bits проверяются до переноса;
- destination version не перезаписывается: совпадающий hash переиспользуется,
  несовпадающий блокирует установку;
- `current` меняется через новую соседнюю symlink + атомарный `mv`;
- cleanup принимает только созданный этим процессом exact temp с ожидаемым
  prefix; пустой, `/`, `$HOME` и runtime root отклоняются.

Подпись tag, известный signer и immutable release проверяются release-процессом
через `gh release verify`/`gh release verify-asset` до публикации one-liner.
Клиентская trust anchor — literal SHA в уже полученной команде; bootstrap не
притворяется, что может независимо доверять GitHub metadata до установки `gh`.

### 7.3 Обновление и удаление bundle

Новая версия ставится рядом со старой. Предыдущая остаётся до успешного
`vibe-mac-verify`. Launchers являются маленькими статическими файлами с
allowlisted target `~/.vibe-mac/current/...`.

Uninstall сначала копирует свой минимальный runtime в exact temp, сверяет его
SHA, и лишь затем может удалить launchers/current/release. State, логи и
`~/.vibe-mac-backup` по умолчанию сохраняются для восстановления; их ручная
очистка печатается отдельно.

## 8. Общие библиотеки

### 8.1 `lib/ui.sh`

- `info`, `success`, `warn`, `fail` и стабильная строка статуса;
- `confirm` читает из `/dev/tty` и принимает только явное русское/латинское
  подтверждение;
- `confirm_typed` для `INTEL`;
- без TTY auth/GUI/defaults пропускаются безопасно, а обязательный системный
  шаг завершается с точной ручной инструкцией;
- ANSI включается только при TTY; текст остаётся понятным без цвета.

### 8.2 `lib/guard.sh`

- macOS, major version 14+, `arm64`;
- Intel: fail-closed; opt-in только
  `ALLOW_UNSUPPORTED_INTEL=1` + сначала показанный Intel DRY_RUN + typed
  `INTEL`;
- запрет запуска всего install как root;
- минимум 15 GiB на filesystem `$HOME`;
- точный Homebrew prefix: `/opt/homebrew` для arm64,
  `/usr/local` для unsupported Intel;
- доступность hardcoded HTTPS sources только в real run;
- канонизация и allowlist путей;
- проверка, что GUI app является ожидаемым bundle в `/Applications`.

15 GiB покрывают CLT, GUI casks, два runtime, package/cache/staging overhead и
запас; installer печатает фактический available/required размер.

### 8.3 `lib/util.sh`

- `have` без вывода;
- `retry`: максимум три общих попытки с задержками 1 и 2 секунды;
- wrapper загрузки: HTTPS-only, hardcoded URL, curl fail/redirect/TLS flags,
  exact destination, затем literal SHA;
- retry не применяется к auth, `sudo`, GUI, defaults, GitHub writes и
  uninstall;
- backup + SHA, managed-block replace без дублей;
- JSON temp/`plutil`/lint/atomic mv;
- lock, normalized path, manifest ownership;
- explicit logging wrapper с redaction; глобального `set -x` и полного
  `tee` нет;
- auth-команды выполняются вне capture и в лог попадает только итоговый enum
  `authenticated`/`needs-login`/`unknown`.

Package managers используют собственную checksum-проверку. Весь `brew bundle`
и `mise install` не оборачиваются в слепой retry после частичной мутации;
повторный запуск идёт через обычный detect/verify/resume.

## 9. Пошаговая реализация

### `00-preflight`

**Detect/verify:** OS, major version, arch, root, flags, Bash 3.2-compatible
окружение, disk, bundle integrity, локальные команды; в real run — сеть и
возможность показать `sudo`-фазу.

**Apply:** отсутствует. Только после успешного read-only preflight оркестратор
создаёт private runtime dirs/log/lock и отмечает шаг. Unsupported платформа и
DRY_RUN не оставляют следов.

### `10-xcode-clt`

**Detect:** `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` и
`xcode-select -p`; Xcode.app не считается требованием.

**Apply:** объяснить «это Command Line Tools, не Xcode.app, около 1 ГБ» →
Enter → `xcode-select --install` → числовой poll `N/TOTAL` → повторная
проверка. Никакого auto-click или скрытого GUI.

### `20-homebrew`

**Detect:** `brew --prefix`, архитектура binary и expected prefix.

**Apply при отсутствии:** заранее скачать installer точного commit в temp,
сверить SHA-256, показать источник/checksum и список privilege effects →
подтверждение → `sudo -v` → запустить только проверенный pinned installer с
`NONINTERACTIVE=1` → `sudo -k` → shellenv → verify. Скачивания между `sudo -v`
и `sudo -k` нет. Пароль читает только `sudo` и он не логируется.

Существующий корректный Homebrew не обновляется. Неожиданный prefix/архитектура
завершает шаг без попытки «починить» ownership рекурсивным `chown`.

### `30-brew-bundle`

**Detect:** exact Homebrew receipts, внешние GUI paths/CLI versions, snapshots.

**Apply:** основной `Brewfile` и при `EXTRAS=1` extras с контрактом раздела 5.
После каждого bundle — независимый check каждого обязательного компонента,
фактические версии и ownership manifest.

### `40-shell`

Используется только системный `/bin/zsh`; `brew "zsh"` и молчаливый `chsh`
запрещены. Если login shell другой, даётся ручной hint `chsh -s /bin/zsh`.

- Oh My Zsh: если `~/.oh-my-zsh` отсутствует, скачать tarball exact commit,
  проверить SHA-256 и распаковать без install script; существующий каталог не
  fetch/reset/update.
- `~/.zprofile` managed block: Homebrew shellenv, `~/.vibe-mac/bin`,
  `~/.local/bin` и `mise activate zsh --shims`.
- `~/.zshrc` managed block: минимальный OMZ `plugins=(git)` без `dotenv` и
  без OMZ plugin `mise`; source aliases; explicit `mise activate zsh`;
  conditional fzf/zoxide; Starship **последним**.
- Если `~/.config/starship.toml` уже есть, сохранить и использовать его. Если
  нет — поставить template как owned file.
- Ghostty: backup и exact managed block в
  `~/Library/Application Support/com.mitchellh.ghostty/config`; существующий
  текст вне блока сохраняется.
- Каждый файл backup-ится один раз до первой записи; rerun не создаёт новый
  backup без смыслового изменения.

### `50-runtimes`

```bash
mise install node@24.18.1 python@3.12.13
```

Если global defaults отсутствуют на чистом Mac:

```bash
mise use --global --pin node@24.18.1 python@3.12.13
```

Существующий global mise config не меняется. Проект всегда получает точный
`.mise.toml`. Проверка:

```bash
mise -C "$HOME/dev/hello-vibe" exec -- node --version
mise -C "$HOME/dev/hello-vibe" exec -- python --version
uv --version
```

Так как workspace создаётся на шаге `90`, шаг `50` сначала проверяет versions
через временный **read-only config path внутри bundle**, а финальный verifier —
через workspace. Temp для runtime install создаёт сам mise в своих штатных
каталогах только в real run.

### `60-ai-agents`

Установка бинарников уже выполнена Brewfile. Проверки:

```bash
claude --version
codex --version
cursor --version
cursor-agent --version
```

Интерактивно, по одному: объяснение аккаунта → Enter → официальный вход →
status. Raw output статуса в лог не записывается.

```bash
claude auth login
claude auth status --text
codex login
codex login status
cursor-agent login
cursor-agent status
```

Cursor Desktop login остаётся ручным GUI-пунктом: документированной terminal
auth status нет. `open -a Cursor` выполняется только после отдельного Enter.
Отложенный login не делает установленный binary красным.

### `70-git-github`

- Проверить Homebrew Git/`gh` и версии.
- Только для отсутствующих ключей задать:

```bash
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
```

- `user.name`/`user.email` запросить у пользователя или позволить отложить;
  не угадывать, не логировать, не перезаписывать.
- GitHub: объяснение → Enter → `gh auth login --web --git-protocol https` →
  подавленная `gh auth status`.
- Не создавать remote/repository, не commit/push/publish.

### `80-defaults`

При `SKIP_DEFAULTS=1` — `Пропущено` без чтения/записи manifest entry.
Иначе показать две exact настройки и получить подтверждение:

```bash
defaults write com.apple.dock autohide -bool true
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
```

До записи сохранить existence/value каждого bool. `killall Dock` и
`killall Finder` заранее раскрываются как видимый перезапуск UI и выполняются
только после подтверждения. Uninstall восстанавливает прежний bool либо
удаляет только ключ, которого раньше не было.

### `90-workspace`

Если `~/dev/hello-vibe` существует — не менять его и показать конфликт/ручной
путь. Если отсутствует:

- создать `index.html`, `AGENTS.md`, `CLAUDE.md`, `FIRST-PROMPT.md`,
  `.mise.toml`;
- `git init -b feat/first-page`;
- не создавать commit, remote, push или deploy;
- первый промпт разрешает Claude менять только `index.html` и не публиковать;
- после явного Enter — `open index.html`.

Доктрина проекта содержит запреты на секреты/PII/PHI, правило Azure Key Vault
`kv-bronxtc-dev` для adarasoft, отдельные worktree/branch/PR, запрет
`git add -A`, `--no-verify`, force-push и прямой работы в `main`/`master`.
Глобальные `~/.codex/AGENTS.md` и `~/.claude/CLAUDE.md` остаются byte-for-byte.

## 10. Verify, doctor и uninstall

### 10.1 `verify.sh`

Read-only агрегаты и основные probes:

| № | Критерий | Ключевая проверка |
|---:|---|---|
| 1 | CLT | pkg receipt + `xcode-select -p` |
| 2 | Homebrew | expected prefix + `brew --version` |
| 3 | Git/GitHub CLI | `git --version` + `gh --version` |
| 4 | Ghostty | exact `/Applications/Ghostty.app` |
| 5 | Shell | `/bin/zsh`, OMZ, Starship, font, managed activation |
| 6 | CLI-набор | rg/fd/fzf/bat/eza/jq/tree/zoxide |
| 7 | mise | version >= tested minimum + zprofile/zshrc activation |
| 8 | Node | project-context exact `v24.18.1` |
| 9 | Python | project-context exact `Python 3.12.13` |
| 10 | uv | команда и parseable version |
| 11 | AI | четыре binaries + Cursor.app; auth отдельно |
| 12 | Workspace | exact files, Git repo, doctrine, no remote |

Каждый красный агрегат содержит ровно одну команду:

```bash
/bin/bash "$HOME/.vibe-mac/current/install.sh"
```

Если bundle отсутствует/повреждён, это exit `2` и README versioned bootstrap
hint, а не фиктивная repair-команда. Внизу: `N из 12 готово`, фактические
версии и отдельные auth статусы GitHub/Claude/Codex/Cursor Agent/ручной Cursor
Desktop. Exit `0/1/2` строго соответствует ТЗ.

### 10.2 `doctor.sh`

Без флагов:

- не создаёт даже temp/log;
- проверяет prefix/PATH, managed blocks, конфликтующие binaries, точечные права,
  JSON schema, hashes, backup targets, symlink/current и stale lock;
- печатает диагноз и план, не запускает package manager/auth/defaults/open/sudo.

`doctor.sh --repair` сначала строит полный read-only план, затем требует
подтверждение. Allowlist ремонта:

- восстановить отсутствующий **точный** managed PATH/activation block;
- исправить mode только у точных owned `~/.vibe-mac` files;
- удалить доказанно stale exact lock.

Никаких recursive `chown`, package reinstall, auth или defaults.

### 10.3 `uninstall.sh`

- default и `--dry-run`: zero-write, точный план;
- применение: только `--apply` + показ целей + typed `UNINSTALL`;
- corrupt/missing/unknown-schema manifest — fail-closed;
- direct preexisting packages, CLT, Homebrew, workspace, accounts, credentials,
  logs и backups не удаляются;
- owned Brew packages удаляются обычным uninstall без `zap` только если receipt
  и ownership всё ещё совпадают и нет installed dependents;
- managed block удаляется только при совпадении его hash; пользовательский
  конфликт остаётся;
- owned OMZ/config удаляется только при неизменном applied hash;
- defaults восстанавливаются из typed manifest;
- executable runtime заранее копируется и проверяется в exact temp;
- широкие glob и невалидированный `rm -rf` отсутствуют.

После apply печатается, что сохранено и как вручную удалить архивные
state/log/backups, если пользователь действительно этого хочет.

## 11. Логи, секреты и human gates

- Логируется только наша структурированная строка команды из allowlist, без
  environment/arguments, которые могут содержать credential.
- Никакого `set -x`.
- `sudo`, `gh auth`, `claude auth`, `codex login`,
  `cursor-agent login/status` выполняются вне stdout/stderr capture.
- Canary password/token/OAuth output в тестах не должен появляться ни в
  success-, ни в error-log.
- Installer не читает `~/.ssh`, `~/.aws`, `~/.azure`, `~/.kube`,
  credential stores или содержимое auth-файлов.
- Никаких secret env, `.env`, API keys или вставки токена в командную строку.
- Единственная root-фаза MVP — verified Homebrew installation, если Homebrew
  отсутствует. До неё artifact уже скачан/проверен; пользователь видит effects,
  подтверждает, выполняется `sudo -v`, pinned script, `sudo -k`.
- CLT/defaults/browser/GUI имеют независимую последовательность
  `объяснение → Enter → команда → проверка`.

## 12. Тестовая матрица

### 12.1 Sandbox

Каждый Bats test получает:

- новый `TEST_ROOT` и синтетический `HOME`;
- fake `PATH` со stubs brew/mise/git/gh/curl/sudo/defaults/open/killall/auth;
- test adapter для plutil;
- event trace и filesystem snapshot;
- нулевой реальный network/sudo/GUI/package install.

Настоящий `HOME` и глобальные agent-файлы хэшируются до/после policy smoke и
должны совпасть.

### 12.2 Обязательные группы

1. **Unit:** UI, have, retry 3 attempts/1+2 backoff, redaction, normalized paths,
   managed blocks, backup, lock, atomic state/manifest, OS/arch/disk guards.
2. **Orchestration:** порядок `00`–`90`, failure injection на каждом шаге,
   resume, stop-on-error, marker only after verify.
3. **Idempotency:** два полных sandbox run; одинаковые files/state semantics и
   отсутствие новых mutating/network events во втором run.
4. **DRY_RUN:** zero-write/network/sudo/GUI/auth/temp/log/lock. Сначала
   malicious fixture доказывает, что tripwire действительно краснеет.
5. **Preexisting:** formula/cask, external apps/CLI, Git/mise globals, zsh/
   Ghostty/Starship configs и global agent files не меняются; dependency-delta
   корректно классифицируется отдельно.
6. **Bootstrap:** wrong checksum, truncated archive, absolute/`..` entry,
   symlink/hardlink, wrong top directory, existing mismatched release,
   symlink escape, failure cleanup.
7. **Brew policy:** exact allowlist, extras isolation, forbidden-stack absence,
   no upgrade/cleanup/zap/pin.
8. **Human gates:** без Enter не вызываются CLT/sudo/defaults/open/auth;
   auth не retry-ится и не логируется.
9. **Verify:** все 12 green/red cases, каждый member агрегата отдельно,
   exit `0/1/2`, одна repair command.
10. **Doctor:** default tripwire zero-write; repair only allowlist/approval.
11. **Uninstall:** baseline → fake install → user edit → dry-run/apply;
    missing/corrupt manifest, `..`, absolute path, symlink/backup substitution,
    preexisting package и changed file fail closed.
12. **Workspace/doctrine:** existing directory untouched; new repo без commit,
    remote/push/deploy; exact secret/PII/Git policy.

Тестовые fixtures хранятся в Git либо детерминированно строятся из tracked
текста. Тест, зависящий от ignored `output/`/`tmp/`, не считается покрытием.

### 12.3 Static и CI

`scripts/check.sh` запускает:

```bash
find . -type f -name '*.sh' -print0 | xargs -0 -n 1 /bin/bash -n
shellcheck --shell=bash bootstrap.sh install.sh verify.sh doctor.sh uninstall.sh lib/*.sh steps/*.sh scripts/*.sh
bats tests/unit tests/integration tests/policy
DRY_RUN=1 /bin/bash ./install.sh
DRY_RUN=1 /bin/bash ./doctor.sh
/bin/bash ./uninstall.sh --dry-run
```

CI:

- Ubuntu: checkout, ShellCheck, Bats, весь sandbox suite;
- macOS 14 arm64: assert `uname -m = arm64`, `/bin/bash --version`,
  `bash -n` и read-only DRY_RUN/tripwire;
- checkout action pinned на
  `actions/checkout@11d5960a326750d5838078e36cf38b85af677262`
  (tag `v4.4.0`), не mutable tag;
- macOS smoke не ставит CLT/Homebrew/packages и не вызывает сеть/GUI/sudo.

Если выбранный hosted label перестанет быть arm64, job падает честно; он не
подменяется Intel smoke. Реальный clean-Mac install остаётся release-гейтом.

## 13. Порядок реализации и контрольные точки

Работа идёт тестами по слоям. После каждого слоя: `bash -n`, ShellCheck,
релевантный Bats, `git diff --check` и secret scan. Число тестов сообщается
только вместе с проверенным commit SHA.

### Gate 2 — документы

- [x] Утверждённое ТЗ сохранено на базе `4bc5da0`.
- [x] Проверены package names, официальные требования и pins.
- [x] Подготовлены точные Brewfile/Brewfile.extras и архитектура.
- [x] Владелец явно утвердил `plan.md` и поправки A1/A2.

### Layer 1 — contracts и безопасное ядро

- [x] Внести A1/A2 в ТЗ; сменить status плана на approved.
- [x] Создать test harness и сначала красные tests для guard/state/dry-run.
- [x] Реализовать `ui.sh`, `guard.sh`, `util.sh`.
- [x] Реализовать `install.sh`, `00`, `10`, `20` и templates JSON.
- [x] Проверить Bash 3.2, state atomicity, sudo/GUI gates.
- [x] Маленький атомарный commit после secret scan.

### Layer 2 — packages, shell, runtimes

- [x] Красные tests exact Brew policy/preexisting/managed blocks/runtime pins.
- [x] Реализовать Brewfiles, `30`, `40`, `50` и config templates.
- [x] Доказать idempotency и dependency-delta report.
- [x] Маленький атомарный commit после secret scan.

### Layer 3 — agents, Git, defaults, first win

- [ ] Красные tests auth isolation/human gates/default restore/workspace.
- [ ] Реализовать `60`, `70`, `80`, `90`.
- [ ] Проверить глобальные agent files byte-for-byte и отсутствие внешних writes.
- [ ] Маленький атомарный commit после secret scan.

### Layer 4 — operations и supply chain

- [ ] Красные tests `verify`/`doctor`/`uninstall`/bootstrap attacks.
- [ ] Реализовать три operational scripts и launchers.
- [ ] Реализовать bootstrap template и local deterministic release fixture.
- [ ] Проверить все fail-closed cases и temp cleanup.
- [ ] Маленький атомарный commit после secret scan.

### Layer 5 — миграция, docs, CI

- [ ] Удалить exact legacy map из раздела 4.4.
- [ ] Переписать `AGENTS.md`, README и troubleshooting.
- [ ] Добавить CI/policy checks и подтвердить отсутствие forbidden stack.
- [ ] Выполнить полный suite дважды на одном commit SHA.
- [ ] Маленький атомарный commit после secret scan.

### Gate 3 — независимое ревью и PR

- [ ] `git fetch origin` и повторная синхронизация с актуальным `origin/main`.
- [ ] Проверить каждый упавший тест на чистом `origin/main` до объявления
  регрессией.
- [ ] Независимый read-only reviewer: blocker/high = 0.
- [ ] `scripts/check.sh`, полный Bats, idempotency, diff secret scan на final SHA.
- [ ] Проверить `git status` и `git branch -vv`.
- [ ] Push только `codex/vibe-mac-refactor` и открыть PR; не merge.

### Отдельный release-гейт

- [ ] Повторно проверить pins и official requirements.
- [ ] Signed tag + immutable GitHub release + archive/checksums.
- [ ] `gh release verify` и `gh release verify-asset` от известного signer.
- [ ] Clean Apple Silicon macOS 14+ full install с записанными version/SHA/OS.
- [ ] Интерактивные входы, `12/12`, второй install без дельты, doctor,
  uninstall dry-run.
- [ ] Только после этого заменить README placeholder production one-liner.

## 14. Локальные команды приёмки перед PR

```bash
git fetch origin
git status --short
git branch -vv
git diff --check origin/main...HEAD

./scripts/check.sh
./scripts/check.sh

./scripts/secret-scan.sh --range origin/main...HEAD
git diff --name-status origin/main...HEAD
git diff --stat origin/main...HEAD
```

Дополнительно сверяется, что diff не содержит secret-like значений, forbidden
packages, старых маршрутных ссылок, mutable production URL или готовой
release-команды с placeholder, выданной за рабочую.

## 15. Критерий завершения кодового PR

Кодовый PR готов, если:

- дерево и поведение соответствуют утверждённым ТЗ/плану;
- все обязательные тесты зелёные на одном указанном SHA;
- DRY_RUN/doctor/uninstall default доказаны zero-write;
- повторный sandbox install идемпотентен;
- preexisting и ownership contracts покрыты негативными тестами;
- secret scan чист;
- blocker/high после независимого ревью отсутствуют;
- PR открыт из рабочей ветки, но не смержен;
- production bootstrap всё ещё явно закрыт release-гейтом.

## 16. Решение, которое требуется сейчас

Следующее действие после явной фразы **«План утверждаю»**:

1. внести A1/A2 в спецификацию;
2. отметить этот документ approved;
3. начать Layer 1 с красных sandbox-тестов;
4. не выполнять реальные установки, входы, публикацию или production release.
