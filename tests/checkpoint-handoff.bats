#!/usr/bin/env bats
# Регрессионный тест перехода Фаза 0 → Фаза 1 (handoff в LMS).
# Баг: успешный 07-checkpoint/self-check.sh говорил «можно идти в Фазу 1»,
# но не давал ни ссылку на LMS, ни рабочую папку, ни точный следующий шаг —
# и гид продолжал искать Фазу 1 внутри этого репозитория.
# Имена тестов держим в ASCII: часть версий bats спотыкается на кириллице.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SANDBOX="$(mktemp -d)"

  # Песочница-копия runbook'а: self-check пишет в state/ и читает ../scripts —
  # работаем на копии, чтобы не трогать настоящий репозиторий.
  mkdir -p "$SANDBOX/repo/scripts" "$SANDBOX/repo/07-checkpoint" "$SANDBOX/repo/state"
  cp "$REPO_ROOT/scripts/lib.sh" "$SANDBOX/repo/scripts/"
  cp "$REPO_ROOT/07-checkpoint/self-check.sh" "$SANDBOX/repo/07-checkpoint/"

  # Фейковый HOME с учебным проектом и сайтом (оба трека пройдены).
  FAKE_HOME="$SANDBOX/home"
  mkdir -p "$FAKE_HOME/vibecoding/vibecoding_first_app" \
           "$FAKE_HOME/vibecoding/vibecoding_first_site/.netlify"
  touch "$FAKE_HOME/vibecoding/vibecoding_first_app/pubspec.yaml"
  touch "$FAKE_HOME/vibecoding/vibecoding_first_site/index.html"
  touch "$FAKE_HOME/vibecoding/vibecoding_first_site/.netlify/state.json"
  echo "05w-netlify:installed" > "$SANDBOX/repo/state/progress.log"

  # Заглушки всех команд чек-листа — имитируем машину, где всё установлено.
  STUB="$SANDBOX/bin"
  mkdir -p "$STUB"
  for cmd in brew gh node npm claude codex flutter netlify; do
    printf '#!/bin/sh\nexit 0\n' > "$STUB/$cmd"
  done
  # git должен отвечать на rev-parse/remote и отдавать >20 файлов в ls-files.
  cat > "$STUB/git" <<'EOF'
#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = "ls-files" ]; then
    i=0; while [ $i -lt 25 ]; do echo "file$i"; i=$((i+1)); done
    exit 0
  fi
done
echo ok
EOF
  chmod +x "$STUB"/*
}

teardown() {
  rm -rf "$SANDBOX"
}

run_checkpoint() {
  HOME="$FAKE_HOME" PATH="$STUB:/usr/bin:/bin" \
    bash "$SANDBOX/repo/07-checkpoint/self-check.sh"
}

@test "checkpoint 14/14: all checks pass and phase 0 is done" {
  run run_checkpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"14 из 14"* ]]
  [[ "$output" == *"Фаза 0 пройдена"* ]]
}

@test "checkpoint success: output contains LMS course URL" {
  run run_checkpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://academy.adarasoft.com/course/vibecoding"* ]]
}

@test "checkpoint success: output names the phase-1 working folder" {
  run run_checkpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"vibecoding/vibecoding_first_app"* ]]
}

@test "checkpoint success: output says runbook is finished and phase 1 lives outside this repo" {
  run run_checkpoint
  [ "$status" -eq 0 ]
  # setup-runbook завершён…
  [[ "$output" == *"завершён"* ]]
  # …а материалы Фазы 1 — не в этом репозитории
  [[ "$output" == *"не в этом репозитории"* || "$output" == *"НЕ в этом репозитории"* ]]
}

@test "checkpoint success with flutter skipped: LMS link yes, dead-end cd no" {
  # Веб-трек без Flutter (8/10): ссылка на LMS есть, а команды «перейди в
  # ~/vibecoding/vibecoding_first_app» нет — этой папки у человека не существует.
  printf '05-flutter:skipped\n05w-netlify:installed\n' > "$SANDBOX/repo/state/progress.log"
  rm -f "$STUB/flutter"
  rm -rf "$FAKE_HOME/vibecoding/vibecoding_first_app"
  run run_checkpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"Фаза 0 пройдена"* ]]
  [[ "$output" == *"https://academy.adarasoft.com/course/vibecoding"* ]]
  [[ "$output" != *"vibecoding_first_app"* ]]
}

@test "checkpoint below threshold: no LMS handoff shown" {
  # Ломаем базу до 1/6. ВАЖНО: заглушки перезаписываем на exit 1, а не удаляем —
  # если убрать brew из PATH, ensure_brew_in_path подтянет НАСТОЯЩИЙ Homebrew
  # машины разработчика, и тест начнёт зависеть от её окружения (флак).
  for cmd in brew gh node npm; do
    printf '#!/bin/sh\nexit 1\n' > "$STUB/$cmd"
  done
  # claude/codex проверяются через command -v (существование файла) — их удаляем;
  # заглушка brew осталась в PATH, так что утечки в реальную систему нет.
  rm -f "$STUB/claude" "$STUB/codex"
  run run_checkpoint
  [[ "$output" != *"academy.adarasoft.com"* ]]
  [[ "$output" == *"ниже порога"* ]]
}
