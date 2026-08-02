#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
}

@test "репозиторий не хранит env-файлы или типичные secret assignments" {
  run /bin/bash -c '
    if git -C "$PROJECT_ROOT" ls-files | /usr/bin/grep -E "(^|/)\\.env([.]|$)"; then
      exit 1
    fi
    if rg -n "^(AWS_SECRET_ACCESS_KEY|AZURE_CLIENT_SECRET|GITHUB_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY)=" \
      "$PROJECT_ROOT" \
      --glob "*.sh" --glob "*.bash" --glob "*.json" --glob "*.toml" --glob "*.yml" --glob "*.yaml"; then
      exit 1
    fi
  '

  [ "$status" -eq 0 ]
}

@test "active scripts не читают credential stores и не исполняют curl pipe shell" {
  run /bin/bash -c '
    files="$PROJECT_ROOT/bootstrap.sh $PROJECT_ROOT/install.sh $PROJECT_ROOT/verify.sh $PROJECT_ROOT/doctor.sh $PROJECT_ROOT/uninstall.sh"
    for file in $PROJECT_ROOT/lib/*.sh $PROJECT_ROOT/steps/*.sh $PROJECT_ROOT/scripts/*.sh; do
      files="$files $file"
    done
    if rg -n "(~/|\\$HOME/)[.](ssh|aws|azure|kube)(/|$)|curl[^|]*[|][[:space:]]*(/bin/)?(ba)?sh" $files; then
      exit 1
    fi
  '

  [ "$status" -eq 0 ]
}

@test "uninstall не содержит широких или принудительных удалений" {
  run rg -n -i \
    'rm[[:space:]]+-rf|brew[[:space:]]+(cleanup|autoremove)|bundle[[:space:]]+cleanup|--zap|--force|--ignore-dependencies|auth[[:space:]]+logout' \
    "$PROJECT_ROOT/uninstall.sh"

  [ "$status" -eq 1 ]
}

@test "CI использует immutable checkout и единый check script" {
  run /bin/bash -c '
    all_checkout="$(rg -c "uses: actions/checkout@" "$PROJECT_ROOT/.github/workflows/ci.yml")" &&
    exact_checkout="$(rg -c "uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262$" "$PROJECT_ROOT/.github/workflows/ci.yml")" &&
    [ "$all_checkout" -gt 0 ] &&
      [ "$all_checkout" = "$exact_checkout" ] &&
      ! rg -n "actions/checkout@v[0-9]" "$PROJECT_ROOT/.github/workflows/ci.yml" &&
      /usr/bin/grep -Fq "./scripts/check.sh" "$PROJECT_ROOT/.github/workflows/ci.yml" &&
      [ -x "$PROJECT_ROOT/scripts/check.sh" ] &&
      [ -x "$PROJECT_ROOT/scripts/secret-scan.sh" ]
  '

  [ "$status" -eq 0 ]
}

@test "check script рекурсивно собирает все три Bats-группы" {
  /usr/bin/grep -Fq '"$PROJECT_ROOT/tests/unit"' \
    "$PROJECT_ROOT/scripts/check.sh"
  /usr/bin/grep -Fq '"$PROJECT_ROOT/tests/integration"' \
    "$PROJECT_ROOT/scripts/check.sh"
  /usr/bin/grep -Fq '"$PROJECT_ROOT/tests/policy"' \
    "$PROJECT_ROOT/scripts/check.sh"
  /usr/bin/grep -Fq -- "-name '*.bats'" \
    "$PROJECT_ROOT/scripts/check.sh"
  /usr/bin/grep -Fq 'bats "$@"' "$PROJECT_ROOT/scripts/check.sh"

  run rg -n 'bats[[:space:]]+tests/?([[:space:]]|$)' \
    "$PROJECT_ROOT/scripts/check.sh"
  [ "$status" -eq 1 ]
}
