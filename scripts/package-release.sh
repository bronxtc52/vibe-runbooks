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
  # The archive URL is rendered inside a shell assignment in bootstrap.sh.
  # Keep the accepted alphabet deliberately smaller than generic RFC 3986 so
  # command substitutions, quotes and sed replacement metacharacters cannot
  # cross that trust boundary.
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  printf '%s\n' "$1" |
    LC_ALL=C /usr/bin/grep -Eq \
      '^https://[A-Za-z0-9][A-Za-z0-9._~:/?%+=,@!-]*$'
}

git_release() {
  /usr/bin/env -i \
    HOME=/var/empty \
    PATH=/usr/bin:/bin \
    LC_ALL=C \
    TZ=UTC \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git \
    -c core.attributesFile=/dev/null \
    -c core.fsmonitor=false \
    -C "$REPO" "$@"
}

validate_git_attributes() {
  local worktree_git_dir common_git_dir metadata_dir attributes_file
  worktree_git_dir="$(git_release rev-parse --absolute-git-dir)" ||
    fail "git metadata repo не читается."
  common_git_dir="$(git_release rev-parse \
    --path-format=absolute --git-common-dir)" ||
    fail "common git metadata repo не читается."

  for metadata_dir in "$worktree_git_dir" "$common_git_dir"; do
    attributes_file="$metadata_dir/info/attributes"
    if [ -e "$attributes_file" ] || [ -L "$attributes_file" ]; then
      fail "info/attributes запрещён в git metadata release repo."
    fi
  done
}

validate_archive_build_marker() {
  local tar_path member variable extracted expected count
  tar_path="$1"
  member="$2"
  variable="$3"
  extracted="$PACKAGE_TEMP/archive-build-marker"
  expected="${variable}='$COMMIT'"

  /usr/bin/tar -xOf "$tar_path" \
    "vibe-mac-$VERSION/$member" >"$extracted" 2>/dev/null ||
    fail "$member отсутствует в release archive."
  count="$(/usr/bin/grep -Fxc "$expected" "$extracted" || true)"
  [ "$count" -eq 1 ] ||
    fail "$member не содержит exact commit build marker."
  if /usr/bin/grep -Fq '$Format:%H$' "$extracted"; then
    fail "$member содержит unsubstituted archive placeholder."
  fi
  /bin/bash -n "$extracted" ||
    fail "$member имеет некорректный shell syntax после export-subst."
}

validate_tree() {
  local path
  if git_release ls-tree -r "$COMMIT" |
    LC_ALL=C /usr/bin/grep -Eq '^(120000|160000) '; then
    fail "tracked symlink или submodule запрещён в release."
  fi
  while IFS= read -r -d '' path; do
    case "$path" in
      ""|/*|*\\*|*"/../"*|*"/./"*|*"//"*|*$'\n'*|*$'\r'*|*$'\t'*)
        fail "tracked path небезопасен."
        ;;
    esac
  done < <(git_release ls-tree -rz --name-only "$COMMIT")
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
validate_git_attributes
case "$COMMIT" in
  *[!A-Fa-f0-9]*|"") fail "commit должен быть full SHA." ;;
esac
[ "${#COMMIT}" -eq 40 ] || fail "commit должен быть full 40-char SHA."
resolved="$(git_release rev-parse --verify "$COMMIT^{commit}" 2>/dev/null)" ||
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
git_release cat-file -e "$COMMIT:bootstrap.sh" 2>/dev/null ||
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

git_release archive \
  --format=tar \
  --prefix="vibe-mac-$VERSION/" \
  "$COMMIT" >"$tar_file"
validate_archive_build_marker \
  "$tar_file" lib/util.sh VIBE_MAC_BUILD_COMMIT
validate_archive_build_marker \
  "$tar_file" verify.sh VIBE_MAC_VERIFY_BUILD_COMMIT
validate_archive_build_marker \
  "$tar_file" install.sh VIBE_MAC_INSTALL_BUILD_COMMIT
validate_archive_build_marker \
  "$tar_file" doctor.sh VIBE_MAC_DOCTOR_BUILD_COMMIT
validate_archive_build_marker \
  "$tar_file" uninstall.sh VIBE_MAC_UNINSTALL_BUILD_COMMIT
/usr/bin/gzip -n -c "$tar_file" >"$archive_file"
/bin/unlink "$tar_file"
archive_sha="$(sha256_file_release "$archive_file")"

git_release show "$COMMIT:bootstrap.sh" >"$PACKAGE_TEMP/bootstrap.template"
for placeholder in \
  __VIBE_MAC_RELEASE_VERSION__ \
  __VIBE_MAC_ARCHIVE_URL__ \
  __VIBE_MAC_ARCHIVE_SHA256__ \
  __VIBE_MAC_BOOTSTRAP_BUILD_CHANNEL__; do
  [ "$(/usr/bin/grep -Fc "$placeholder" \
    "$PACKAGE_TEMP/bootstrap.template")" -ge 1 ] ||
    fail "bootstrap template не содержит $placeholder."
done
/usr/bin/sed \
  -e "s|__VIBE_MAC_RELEASE_VERSION__|$VERSION|g" \
  -e "s|__VIBE_MAC_ARCHIVE_URL__|$ARCHIVE_URL|g" \
  -e "s|__VIBE_MAC_ARCHIVE_SHA256__|$archive_sha|g" \
  -e "s|__VIBE_MAC_BOOTSTRAP_BUILD_CHANNEL__|production|g" \
  "$PACKAGE_TEMP/bootstrap.template" >"$bootstrap_file"
/bin/chmod 0700 "$bootstrap_file"
/bin/bash -n "$bootstrap_file"
bootstrap_sha="$(sha256_file_release "$bootstrap_file")"

printf '%s  %s\n' "$archive_sha" "$archive_name" \
  >"$PACKAGE_TEMP/$archive_name.sha256"
printf '%s  %s\n' "$bootstrap_sha" "$bootstrap_name" \
  >"$PACKAGE_TEMP/$bootstrap_name.sha256"

/bin/cat >"$PACKAGE_TEMP/install-command.body" <<'VIBE_MAC_LOADER_BODY'
set -euo pipefail
fail() {
  /usr/bin/printf 'Ошибка: %s\n' "$1" >&2
  exit 2
}
validate_bool() {
  case "$2" in
    0|1) ;;
    *) fail "$1 принимает только 0 или 1." ;;
  esac
}
expected="${VIBE_MAC_LOADER_SHA256:-}"
url="${VIBE_MAC_LOADER_URL:-}"
[ "${#expected}" -eq 64 ] || fail 'bootstrap SHA malformed.'
case "$expected" in *[!0-9a-f]*) fail 'bootstrap SHA malformed.' ;; esac
validate_bool DRY_RUN "${DRY_RUN:-0}"
validate_bool EXTRAS "${EXTRAS:-0}"
validate_bool SKIP_DEFAULTS "${SKIP_DEFAULTS:-0}"
validate_bool ALLOW_UNSUPPORTED_INTEL "${ALLOW_UNSUPPORTED_INTEL:-0}"
if [ "$DRY_RUN" = 1 ]; then
  /usr/bin/printf '%s\n' \
    'DRY_RUN: bootstrap loader не создаёт temp и не вызывает сеть.'
  exit 0
fi
case "$HOME" in /*) ;; *) fail 'HOME должен быть absolute path.' ;; esac
home_control_status=0
/usr/bin/printf '%s' "$HOME" |
  LC_ALL=C /usr/bin/grep -Eq '[[:cntrl:]]' || home_control_status="$?"
case "$home_control_status" in
  0) fail 'HOME содержит control character.' ;;
  1) ;;
  *) fail 'HOME нельзя проверить.' ;;
esac
[ -d "$HOME" ] && [ ! -L "$HOME" ] || fail 'HOME небезопасен.'
home_physical="$(/bin/realpath "$HOME" 2>/dev/null)" ||
  fail 'HOME нельзя канонизировать.'
[ "$home_physical" = "$HOME" ] ||
  fail 'HOME содержит symlink или dot segment.'
run_user="$(/usr/bin/id -un)"
umask 077
temp="$(/usr/bin/mktemp /tmp/vibe-mac-loader.XXXXXX)"
cleanup() {
  [ -z "${temp:-}" ] || /bin/unlink "$temp" 2>/dev/null || true
}
trap cleanup EXIT
/usr/bin/env -i \
  HOME="$HOME" \
  USER="$run_user" \
  LOGNAME="$run_user" \
  SHELL=/bin/zsh \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  TMPDIR=/tmp \
  LC_ALL=C \
  BASH_ENV=/dev/null \
  ENV=/dev/null \
  CURL_HOME=/var/empty \
  XDG_CONFIG_HOME=/var/empty \
  /usr/bin/curl \
  -q \
  --proto '=https' \
  --tlsv1.2 \
  --fail \
  --location \
  --silent \
  --show-error \
  --output "$temp" \
  "$url"
actual="$(/usr/bin/shasum -a 256 "$temp" | /usr/bin/awk '{print $1}')"
[ "$actual" = "$expected" ] || fail 'bootstrap SHA не совпал.'
/usr/bin/env -i \
  HOME="$HOME" \
  USER="$run_user" \
  LOGNAME="$run_user" \
  SHELL=/bin/zsh \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  TMPDIR=/tmp \
  LC_ALL=C \
  TERM=xterm-256color \
  BASH_ENV=/dev/null \
  ENV=/dev/null \
  DRY_RUN="$DRY_RUN" \
  EXTRAS="$EXTRAS" \
  SKIP_DEFAULTS="$SKIP_DEFAULTS" \
  ALLOW_UNSUPPORTED_INTEL="$ALLOW_UNSUPPORTED_INTEL" \
  VIBE_MAC_SHA256="$expected" \
  /bin/bash --noprofile --norc -p "$temp"
VIBE_MAC_LOADER_BODY
loader_body="$(/bin/cat "$PACKAGE_TEMP/install-command.body")"
printf -v loader_body_quoted '%q' "$loader_body"
printf '/usr/bin/env -i HOME="${HOME:-}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp LC_ALL=C TERM=xterm-256color BASH_ENV=/dev/null ENV=/dev/null DRY_RUN="${DRY_RUN:-0}" EXTRAS="${EXTRAS:-0}" SKIP_DEFAULTS="${SKIP_DEFAULTS:-0}" ALLOW_UNSUPPORTED_INTEL="${ALLOW_UNSUPPORTED_INTEL:-0}" VIBE_MAC_LOADER_SHA256=%q VIBE_MAC_LOADER_URL=%q /bin/bash --noprofile --norc -p -c %s\n' \
  "$bootstrap_sha" \
  "$BOOTSTRAP_URL" \
  "$loader_body_quoted" >"$PACKAGE_TEMP/install-command.txt"

loader_line_count="$(/usr/bin/wc -l \
  <"$PACKAGE_TEMP/install-command.txt" | /usr/bin/tr -d ' ')"
[ "$loader_line_count" -eq 1 ] || fail "install-command должен быть одной строкой."
[ -s "$PACKAGE_TEMP/install-command.txt" ] || fail "install-command пуст."
/usr/bin/grep -Fq "$bootstrap_sha" "$PACKAGE_TEMP/install-command.txt" ||
  fail "install-command не содержит literal bootstrap SHA."
loader_line="$(/bin/cat "$PACKAGE_TEMP/install-command.txt")"
/bin/bash -n -c "$loader_line" || fail "install-command не парсится в bash."
if [ -x /bin/zsh ]; then
  /bin/zsh -n -c "$loader_line" || fail "install-command не парсится в zsh."
fi

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
