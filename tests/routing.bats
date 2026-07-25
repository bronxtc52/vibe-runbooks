#!/usr/bin/env bats
# Регрессионные тесты маршрутизации между шагами и фазами (класс «тупик /
# неверный следующий шаг», как в фиксе 07-checkpoint, PR #7).
# Баги: скрипты в хвосте либо молчат про следующий шаг, либо отправляют
# не туда (назад по фазе, в несуществующий файл, в один трек вместо развилки).
# Проверки статические: grep по исходникам, без запуска скриптов.
# Имена тестов держим в ASCII: часть версий bats спотыкается на кириллице.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# --- 03: сторож секретов -> следующий шаг фазы = сторож команд ---------------

@test "secret-guard final hint routes to setup-command-guard.sh" {
  run tail -n 5 "$REPO_ROOT/03-git-github/setup-secret-guard.sh"
  [[ "$output" == *"setup-command-guard.sh"* ]]
}

@test "secret-guard final hint does not route back to setup-git-identity" {
  # Подпись Git по порядку фазы 03 идёт ДО сторожа секретов (см. INDEX.md) —
  # отправлять к ней «дальше» значит гонять новичка по кругу.
  run tail -n 5 "$REPO_ROOT/03-git-github/setup-secret-guard.sh"
  [[ "$output" != *"setup-git-identity"* ]]
}

# --- 03: armanda.txt — след старого бренда, такого файла в курсе нет ---------

@test "secret-guard does not mention armanda.txt" {
  run grep -c "armanda.txt" "$REPO_ROOT/03-git-github/setup-secret-guard.sh"
  [ "$output" = "0" ]
}

# --- 06w: после публикации сайта -> verify.sh и чек-поинт 07 -----------------

@test "publish-site tail routes to verify.sh" {
  run tail -n 12 "$REPO_ROOT/06w-first-site/publish-site.sh"
  [[ "$output" == *"verify.sh"* ]]
}

@test "publish-site tail routes to 07-checkpoint" {
  run tail -n 12 "$REPO_ROOT/06w-first-site/publish-site.sh"
  [[ "$output" == *"07-checkpoint"* ]]
}

# --- 06: после первой петли правка+коммит -> verify.sh и чек-поинт 07 --------

@test "first-edit-commit tail routes to verify.sh" {
  run tail -n 12 "$REPO_ROOT/06-first-win/first-edit-commit.sh"
  [[ "$output" == *"verify.sh"* ]]
}

@test "first-edit-commit tail routes to 07-checkpoint" {
  run tail -n 12 "$REPO_ROOT/06-first-win/first-edit-commit.sh"
  [[ "$output" == *"07-checkpoint"* ]]
}

# --- 04: после фазы 4 — развилка треков, а не безусловный 05-flutter ---------

@test "04 verify success branch mentions both tracks" {
  run cat "$REPO_ROOT/04-ai-helpers/verify.sh"
  [[ "$output" == *"05-flutter"* ]]
  [[ "$output" == *"05w-netlify"* ]]
}

@test "04 runbook what-next section mentions both tracks" {
  # Секция «Что дальше» должна описывать выбор трека (мобильный и/или веб),
  # согласованно с INDEX.md и FOR-CODEX.md («Развилка после фазы 4»).
  run sed -n '/## Что дальше/,$p' "$REPO_ROOT/04-ai-helpers/runbook.md"
  [[ "$output" == *"05-flutter"* ]]
  [[ "$output" == *"05w-netlify"* ]]
}
