#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MODE="${1:-full}"
CHECK_TEMP=
REAL_HOME="${HOME:?HOME не задан}"

usage() {
  printf '%s\n' \
    "Запуск: ./scripts/check.sh [--smoke-only|--lint-only]"
}

cleanup() {
  local exit_code
  exit_code="$?"
  if [ -n "$CHECK_TEMP" ] && [ -d "$CHECK_TEMP" ] &&
    [ ! -L "$CHECK_TEMP" ]; then
    /usr/bin/find "$CHECK_TEMP" -depth -delete
  fi
  return "$exit_code"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Ошибка: для проверки нужна команда %s.\n' "$1" >&2
    exit 2
  fi
}

run_syntax() {
  local failed file
  failed=0
  printf '%s\n' "[1/4] Bash syntax"
  while IFS= read -r -d '' file; do
    /bin/bash -n "$file" || failed=1
  done < <(
    /usr/bin/find "$PROJECT_ROOT" \
      \( -path "$PROJECT_ROOT/.git" \
      -o -path "$PROJECT_ROOT/output" \
      -o -path "$PROJECT_ROOT/dist" \
      -o -path "$PROJECT_ROOT/release" \
      -o -path "$PROJECT_ROOT/tmp" \) -prune \
      -o -type f \( -name '*.sh' -o -name '*.bash' \) -print0
  )
  [ "$failed" -eq 0 ]
}

snapshot_agent_files() {
  local path relative
  for relative in .codex/AGENTS.md .claude/CLAUDE.md; do
    path="$REAL_HOME/$relative"
    if [ -L "$path" ]; then
      printf '%s\tlink\t%s\n' "$relative" "$(/usr/bin/readlink "$path")"
    elif [ -f "$path" ]; then
      printf '%s\tfile\t%s\n' "$relative" "$(cksum <"$path")"
    elif [ -e "$path" ]; then
      printf '%s\tother\n' "$relative"
    else
      printf '%s\tabsent\n' "$relative"
    fi
  done
}

run_smoke() {
  local before after smoke_home runtime state event_log doctor_status
  printf '%s\n' "[2/4] Synthetic zero-write smoke"
  CHECK_TEMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vibe-mac-check.XXXXXX")"
  /bin/chmod 0700 "$CHECK_TEMP"
  smoke_home="$CHECK_TEMP/home"
  runtime="$smoke_home/.vibe-mac"
  state="$runtime/state"
  event_log="$CHECK_TEMP/events.log"
  /bin/mkdir -p "$smoke_home"
  : >"$event_log"

  before="$(snapshot_agent_files)"
  env \
    HOME="$smoke_home" \
    VIBE_MAC_TEST_MODE=1 \
    VIBE_MAC_TEST_OS=Darwin \
    VIBE_MAC_TEST_ARCH=arm64 \
    VIBE_MAC_TEST_MACOS_VERSION=14.7.0 \
    VIBE_MAC_TEST_UID=501 \
    VIBE_MAC_TEST_FREE_KB=31457280 \
    VIBE_MAC_TEST_NETWORK=ok \
    VIBE_MAC_TEST_SYSTEM_TOOLS=ok \
    VIBE_MAC_PLUTIL_BIN="$PROJECT_ROOT/tests/helpers/plutil_stub.py" \
    VIBE_MAC_EVENT_LOG="$event_log" \
    DRY_RUN=1 \
    /bin/bash "$PROJECT_ROOT/install.sh"
  [ ! -e "$runtime" ]
  [ ! -L "$runtime" ]
  [ ! -s "$event_log" ]

  /bin/mkdir -p "$state"
  /bin/chmod 0700 "$runtime" "$state"
  /bin/cp "$PROJECT_ROOT/state/progress-template.json" "$state/progress.json"
  /bin/cp "$PROJECT_ROOT/state/manifest-template.json" "$state/manifest.json"
  /bin/chmod 0600 "$state/progress.json" "$state/manifest.json"

  doctor_status=0
  env \
    HOME="$smoke_home" \
    VIBE_MAC_TEST_MODE=1 \
    VIBE_MAC_PLUTIL_BIN="$PROJECT_ROOT/tests/helpers/plutil_stub.py" \
    DRY_RUN=1 \
    /bin/bash "$PROJECT_ROOT/doctor.sh" --dry-run || doctor_status="$?"
  [ "$doctor_status" -eq 1 ]
  env \
    HOME="$smoke_home" \
    VIBE_MAC_TEST_MODE=1 \
    VIBE_MAC_PLUTIL_BIN="$PROJECT_ROOT/tests/helpers/plutil_stub.py" \
    /bin/bash "$PROJECT_ROOT/uninstall.sh" --dry-run

  after="$(snapshot_agent_files)"
  [ "$before" = "$after" ]
  [ ! -s "$event_log" ]
}

run_shellcheck() {
  local file failed
  failed=0
  printf '%s\n' "[3/4] ShellCheck"
  require_command shellcheck
  for file in \
    "$PROJECT_ROOT/bootstrap.sh" \
    "$PROJECT_ROOT/install.sh" \
    "$PROJECT_ROOT/verify.sh" \
    "$PROJECT_ROOT/doctor.sh" \
    "$PROJECT_ROOT/uninstall.sh" \
    "$PROJECT_ROOT"/lib/*.sh \
    "$PROJECT_ROOT"/steps/*.sh \
    "$PROJECT_ROOT"/scripts/*.sh; do
    shellcheck -x -P "$PROJECT_ROOT" --shell=bash "$file" || failed=1
  done
  [ "$failed" -eq 0 ]
}

run_bats() {
  local list_file file
  printf '%s\n' "[4/4] Recursive Bats suite"
  require_command bats
  list_file="$CHECK_TEMP/bats-files.txt"
  /usr/bin/find \
    "$PROJECT_ROOT/tests/unit" \
    "$PROJECT_ROOT/tests/integration" \
    "$PROJECT_ROOT/tests/policy" \
    -type f -name '*.bats' -print | LC_ALL=C /usr/bin/sort >"$list_file"
  set --
  while IFS= read -r file; do
    set -- "$@" "$file"
  done <"$list_file"
  [ "$#" -gt 0 ]
  bats "$@"
}

case "$MODE" in
  full)
    [ "$#" -eq 0 ] || {
      usage >&2
      exit 2
    }
    ;;
  --smoke-only)
    [ "$#" -eq 1 ] || {
      usage >&2
      exit 2
    }
    ;;
  --lint-only)
    [ "$#" -eq 1 ] || {
      usage >&2
      exit 2
    }
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

umask 077
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
run_syntax
case "$MODE" in
  --lint-only)
    run_shellcheck
    ;;
  --smoke-only)
    require_command python3
    run_smoke
    ;;
  full)
    require_command python3
    run_smoke
    run_shellcheck
    run_bats
    ;;
esac
