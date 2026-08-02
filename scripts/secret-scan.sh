#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MODE=tree
RANGE=

usage() {
  printf '%s\n' \
    "Запуск: ./scripts/secret-scan.sh [--range REV_RANGE|--staged]" \
    "Без флага сканируется текущее рабочее дерево."
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    --range)
      [ "$#" -eq 2 ] || {
        usage >&2
        exit 2
      }
      MODE=range
      RANGE="$2"
      ;;
    --staged)
      [ "$#" -eq 1 ] || {
        usage >&2
        exit 2
      }
      MODE=staged
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
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  printf '%s\n' \
    "Ошибка: gitleaks не найден. Установи его и повтори secret scan." >&2
  exit 2
fi

case "$MODE" in
  tree)
    gitleaks dir --no-banner --no-color --redact "$PROJECT_ROOT"
    ;;
  staged)
    gitleaks git --no-banner --no-color --redact --staged "$PROJECT_ROOT"
    ;;
  range)
    case "$RANGE" in
      ""|-*)
        printf '%s\n' "Ошибка: небезопасный Git range." >&2
        exit 2
        ;;
    esac
    git -C "$PROJECT_ROOT" rev-list "$RANGE" >/dev/null
    gitleaks git \
      --no-banner \
      --no-color \
      --redact \
      --log-opts="$RANGE" \
      "$PROJECT_ROOT"
    ;;
esac
