#!/usr/bin/env bash
# Generated loader lines intentionally keep their runtime variables literal.
# shellcheck disable=SC2016
set -euo pipefail

REPO=
COMMIT=
VERSION=
ARCHIVE_URL=
BOOTSTRAP_URL=
OUTPUT_DIR=
PACKAGE_TEMP=

usage() {
  printf '%s\n' \
    "package-release.sh --repo PATH --commit FULL_SHA --version VERSION" \
    "  --archive-url HTTPS_URL --bootstrap-url HTTPS_URL --output-dir NEW_PATH"
}

fail() {
  printf 'Ошибка: %s\n' "$1" >&2
  exit 2
}

cleanup() {
  local exit_code prefix
  exit_code="$?"
  if [ -n "$PACKAGE_TEMP" ]; then
    prefix="${TMPDIR:-/tmp}/vibe-mac.package."
    case "$PACKAGE_TEMP" in
      "$prefix"*)
        if [ -d "$PACKAGE_TEMP" ] && [ ! -L "$PACKAGE_TEMP" ]; then
          /usr/bin/find "$PACKAGE_TEMP" -depth -delete
        fi
        ;;
    esac
  fi
  return "$exit_code"
}

sha256_file_release() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

validate_url() {
  case "$1" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[\|\&\\[:space:]]*) return 1 ;;
  esac
}

validate_tree() {
  local path
  if git -C "$REPO" ls-tree -r "$COMMIT" |
    LC_ALL=C /usr/bin/grep -Eq '^(120000|160000) '; then
    fail "tracked symlink или submodule запрещён в release."
  fi
  while IFS= read -r -d '' path; do
    case "$path" in
      ""|/*|*\\*|*"/../"*|*"/./"*|*"//"*|*$'\n'*|*$'\r'*)
        fail "tracked path небезопасен."
        ;;
    esac
  done < <(git -C "$REPO" ls-tree -rz --name-only "$COMMIT")
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--commit|--version|--archive-url|--bootstrap-url|--output-dir)
      [ "$#" -ge 2 ] || fail "для $1 отсутствует значение."
      key="$1"
      value="$2"
      shift 2
      case "$key" in
        --repo) REPO="$value" ;;
        --commit) COMMIT="$value" ;;
        --version) VERSION="$value" ;;
        --archive-url) ARCHIVE_URL="$value" ;;
        --bootstrap-url) BOOTSTRAP_URL="$value" ;;
        --output-dir) OUTPUT_DIR="$value" ;;
      esac
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "неизвестный аргумент $1."
      ;;
  esac
done

[ -n "$REPO" ] && [ -n "$COMMIT" ] && [ -n "$VERSION" ] &&
  [ -n "$ARCHIVE_URL" ] && [ -n "$BOOTSTRAP_URL" ] &&
  [ -n "$OUTPUT_DIR" ] || {
    usage >&2
    exit 2
  }

[ -d "$REPO" ] && [ ! -L "$REPO" ] || fail "repo должен быть каталогом."
case "$COMMIT" in
  *[!A-Fa-f0-9]*|"") fail "commit должен быть full SHA." ;;
esac
[ "${#COMMIT}" -eq 40 ] || fail "commit должен быть full 40-char SHA."
resolved="$(git -C "$REPO" rev-parse --verify "$COMMIT^{commit}" 2>/dev/null)" ||
  fail "commit не найден."
[ "$resolved" = "$COMMIT" ] || fail "commit должен быть exact object ID."
case "$VERSION" in
  [A-Za-z0-9]*)
    case "$VERSION" in *[!A-Za-z0-9._-]*|*..*)
      fail "version небезопасна."
      ;;
    esac
    ;;
  *) fail "version небезопасна." ;;
esac
validate_url "$ARCHIVE_URL" || fail "archive URL небезопасен."
validate_url "$BOOTSTRAP_URL" || fail "bootstrap URL небезопасен."
if [ -e "$OUTPUT_DIR" ] || [ -L "$OUTPUT_DIR" ]; then
  fail "output-dir должен отсутствовать."
fi

validate_tree
git -C "$REPO" cat-file -e "$COMMIT:bootstrap.sh" 2>/dev/null ||
  fail "bootstrap.sh отсутствует в exact commit."

umask 077
PACKAGE_TEMP="$(/usr/bin/mktemp -d \
  "${TMPDIR:-/tmp}/vibe-mac.package.XXXXXX")"
/bin/chmod 0700 "$PACKAGE_TEMP"
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

archive_name="vibe-mac-$VERSION.tar.gz"
bootstrap_name="vibe-mac-bootstrap-$VERSION.sh"
tar_file="$PACKAGE_TEMP/vibe-mac-$VERSION.tar"
archive_file="$PACKAGE_TEMP/$archive_name"
bootstrap_file="$PACKAGE_TEMP/$bootstrap_name"

git -C "$REPO" archive \
  --format=tar \
  --prefix="vibe-mac-$VERSION/" \
  "$COMMIT" >"$tar_file"
/usr/bin/gzip -n -c "$tar_file" >"$archive_file"
/bin/unlink "$tar_file"
archive_sha="$(sha256_file_release "$archive_file")"

git -C "$REPO" show "$COMMIT:bootstrap.sh" >"$PACKAGE_TEMP/bootstrap.template"
for placeholder in \
  __VIBE_MAC_RELEASE_VERSION__ \
  __VIBE_MAC_ARCHIVE_URL__ \
  __VIBE_MAC_ARCHIVE_SHA256__; do
  [ "$(/usr/bin/grep -Fc "$placeholder" \
    "$PACKAGE_TEMP/bootstrap.template")" -ge 1 ] ||
    fail "bootstrap template не содержит $placeholder."
done
/usr/bin/sed \
  -e "s|__VIBE_MAC_RELEASE_VERSION__|$VERSION|g" \
  -e "s|__VIBE_MAC_ARCHIVE_URL__|$ARCHIVE_URL|g" \
  -e "s|__VIBE_MAC_ARCHIVE_SHA256__|$archive_sha|g" \
  "$PACKAGE_TEMP/bootstrap.template" >"$bootstrap_file"
/bin/chmod 0700 "$bootstrap_file"
/bin/bash -n "$bootstrap_file"
bootstrap_sha="$(sha256_file_release "$bootstrap_file")"

printf '%s  %s\n' "$archive_sha" "$archive_name" \
  >"$PACKAGE_TEMP/$archive_name.sha256"
printf '%s  %s\n' "$bootstrap_sha" "$bootstrap_name" \
  >"$PACKAGE_TEMP/$bootstrap_name.sha256"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf 'expected=%q\n' "$bootstrap_sha"
  printf 'url=%q\n' "$BOOTSTRAP_URL"
  printf '%s\n' 'if [ "${DRY_RUN:-0}" = 1 ]; then'
  printf '%s\n' '  printf "%s\\n" "DRY_RUN: bootstrap loader не создаёт temp и не вызывает сеть."'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'temp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/vibe-mac-loader.XXXXXX")"'
  printf '%s\n' 'trap '\''/bin/unlink "$temp" 2>/dev/null || true'\'' EXIT'
  printf '%s\n' '/usr/bin/curl --proto "=https" --tlsv1.2 --fail --location --silent --show-error --output "$temp" "$url"'
  printf '%s\n' 'actual="$(/usr/bin/shasum -a 256 "$temp" | /usr/bin/awk '\''{print $1}'\'')"'
  printf '%s\n' '[ "$actual" = "$expected" ] || { printf "%s\\n" "Ошибка: bootstrap SHA не совпал." >&2; exit 2; }'
  printf '%s\n' 'VIBE_MAC_SHA256="$expected" /bin/bash "$temp"'
} >"$PACKAGE_TEMP/install-command.txt"
/bin/bash -n "$PACKAGE_TEMP/install-command.txt"

/bin/mkdir "$OUTPUT_DIR"
/bin/chmod 0700 "$OUTPUT_DIR"
for artifact in \
  "$archive_name" \
  "$bootstrap_name" \
  "$archive_name.sha256" \
  "$bootstrap_name.sha256" \
  install-command.txt; do
  /bin/mv "$PACKAGE_TEMP/$artifact" "$OUTPUT_DIR/$artifact"
done

printf 'Release fixture %s собран из %s.\n' "$VERSION" "$COMMIT"
