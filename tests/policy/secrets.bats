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
    safe_checkout="$(rg -c "persist-credentials: false" "$PROJECT_ROOT/.github/workflows/ci.yml")" &&
    [ "$all_checkout" -gt 0 ] &&
      [ "$all_checkout" = "$exact_checkout" ] &&
      [ "$all_checkout" = "$safe_checkout" ] &&
      ! rg -n "actions/checkout@v[0-9]" "$PROJECT_ROOT/.github/workflows/ci.yml" &&
      /usr/bin/grep -Fq "./scripts/check.sh" "$PROJECT_ROOT/.github/workflows/ci.yml" &&
      [ -x "$PROJECT_ROOT/scripts/check.sh" ] &&
      [ -x "$PROJECT_ROOT/scripts/secret-scan.sh" ]
  '

  [ "$status" -eq 0 ]
}

@test "CI использует pinned официальные test tools с literal SHA-256" {
  workflow="$PROJECT_ROOT/.github/workflows/ci.yml"

  /usr/bin/grep -Fq 'SHELLCHECK_VERSION: "0.11.0"' "$workflow"
  /usr/bin/grep -Fq \
    'SHELLCHECK_ARCHIVE_URL: "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.gz"' \
    "$workflow"
  /usr/bin/grep -Fq \
    'SHELLCHECK_ARCHIVE_SHA256: "b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6"' \
    "$workflow"
  /usr/bin/grep -Fq \
    'SHELLCHECK_ARCHIVE_URL: "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz"' \
    "$workflow"
  /usr/bin/grep -Fq \
    'SHELLCHECK_ARCHIVE_SHA256: "339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f"' \
    "$workflow"
  /usr/bin/grep -Fq 'BATS_VERSION: "1.13.0"' "$workflow"
  /usr/bin/grep -Fq \
    'BATS_COMMIT: "3bca150ec86275d6d9d5a4fd7d48ab8b6c6f3d87"' \
    "$workflow"
  /usr/bin/grep -Fq \
    'BATS_ARCHIVE_URL: "https://codeload.github.com/bats-core/bats-core/tar.gz/3bca150ec86275d6d9d5a4fd7d48ab8b6c6f3d87"' \
    "$workflow"
  /usr/bin/grep -Fq \
    'BATS_ARCHIVE_SHA256: "4f1628b894fb52368cddd6deab97358c500ab8ef337f291ddd779e1760a08a43"' \
    "$workflow"
  /usr/bin/grep -Fq 'RG_VERSION: "15.2.0"' "$workflow"
  /usr/bin/grep -Fq \
    'RG_ARCHIVE_URL: "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz"' \
    "$workflow"
  /usr/bin/grep -Fq \
    'RG_ARCHIVE_SHA256: "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"' \
    "$workflow"
  /usr/bin/grep -Fq 'sha256sum --check --strict' "$workflow"
  /usr/bin/grep -Fq '/usr/bin/shasum -a 256 -c -' "$workflow"
  /usr/bin/grep -Fq 'shellcheck" --version' "$workflow"
  /usr/bin/grep -Fq 'bats" --version' "$workflow"
  /usr/bin/grep -Fq 'rg" --version' "$workflow"

  run rg -n 'apt-get install[^#]*(shellcheck|bats)' "$workflow"
  [ "$status" -eq 1 ]
}

@test "CI запускает static lint на Linux и полный suite на целевом macOS" {
  workflow="$PROJECT_ROOT/.github/workflows/ci.yml"

  /usr/bin/grep -Fq 'name: Linux pinned static lint' "$workflow"
  /usr/bin/grep -Fq 'runs-on: ubuntu-24.04' "$workflow"
  /usr/bin/grep -Fq 'run: ./scripts/check.sh --lint-only' "$workflow"
  /usr/bin/grep -Fq 'name: macOS 14 arm64 full sandbox suite' "$workflow"
  /usr/bin/grep -Fq 'runs-on: macos-14' "$workflow"
  /usr/bin/grep -Fq 'LANG: C' "$workflow"
  /usr/bin/grep -Fq 'LC_ALL: C' "$workflow"
  /usr/bin/grep -Fq '/bin/ln -s /bin/bash "$bin_dir/bash"' "$workflow"
  /usr/bin/grep -Fq 'run: ./scripts/check.sh' "$workflow"

  run rg -n -- '--smoke-only' "$workflow"
  [ "$status" -eq 1 ]

  run rg -n 'apt-get|sudo' "$workflow"
  [ "$status" -eq 1 ]
}

@test "lint-only запускает syntax и ShellCheck без smoke и Bats" {
  load_helpers
  make_recording_command shellcheck 0

  run "$PROJECT_ROOT/scripts/check.sh" --lint-only

  [ "$status" -eq 0 ]
  [[ "$output" = *"[1/4] Bash syntax"* ]]
  [[ "$output" = *"[3/4] ShellCheck"* ]]
  [[ "$output" != *"[2/4] Synthetic zero-write smoke"* ]]
  [[ "$output" != *"[4/4] Recursive Bats suite"* ]]
  assert_file_contains "$VIBE_MAC_EVENT_LOG" 'shellcheck '
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
