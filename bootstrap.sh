#!/usr/bin/env bash
# Launcher bodies intentionally keep runtime variables literal.
# shellcheck disable=SC2016
set -euo pipefail

# These three placeholders are replaced only by scripts/package-release.sh.
RELEASE_VERSION="__VIBE_MAC_RELEASE_VERSION__"
ARCHIVE_URL="__VIBE_MAC_ARCHIVE_URL__"
ARCHIVE_SHA256="__VIBE_MAC_ARCHIVE_SHA256__"

TEMP_DIR=
INCOMING_DIR=
RELEASE_TREE_SHA=

fail_integrity() {
  printf 'Ошибка: %s\n' "$1" >&2
  exit 2
}

fail_operation() {
  printf 'Ошибка: %s\n' "$1" >&2
  exit 1
}

sha256_file_standalone() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail_integrity "не найден SHA-256 инструмент."
  fi
}

sha256_stdin_standalone() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    fail_integrity "не найден SHA-256 инструмент."
  fi
}

cleanup() {
  local exit_code expected_prefix incoming_prefix
  exit_code="$?"
  if [ -n "$INCOMING_DIR" ]; then
    incoming_prefix="$VIBE_MAC_RUNTIME_ROOT/releases/.incoming-$RELEASE_VERSION."
    case "$INCOMING_DIR" in
      "$incoming_prefix"*)
        if [ -d "$INCOMING_DIR" ] && [ ! -L "$INCOMING_DIR" ]; then
          /usr/bin/find "$INCOMING_DIR" -depth -delete
        fi
        ;;
    esac
  fi
  if [ -n "$TEMP_DIR" ]; then
    expected_prefix="${TMPDIR:-/tmp}/vibe-mac.bootstrap."
    case "$TEMP_DIR" in
      "$expected_prefix"*)
        if [ -d "$TEMP_DIR" ] && [ ! -L "$TEMP_DIR" ]; then
          /usr/bin/find "$TEMP_DIR" -depth -delete
        fi
        ;;
      *)
        printf '%s\n' "Внимание: неожиданный temp path не удалён." >&2
        ;;
    esac
  fi
  return "$exit_code"
}

validate_bool_standalone() {
  case "$2" in
    0|1) ;;
    *) fail_integrity "$1 принимает только 0 или 1." ;;
  esac
}

configure_release_values() {
  if [ "${VIBE_MAC_TEST_MODE:-0}" = 1 ]; then
    RELEASE_VERSION="${VIBE_MAC_RELEASE_VERSION:-$RELEASE_VERSION}"
    ARCHIVE_URL="${VIBE_MAC_ARCHIVE_URL:-$ARCHIVE_URL}"
    ARCHIVE_SHA256="${VIBE_MAC_ARCHIVE_SHA256:-$ARCHIVE_SHA256}"
  fi
  case "$RELEASE_VERSION" in
    [A-Za-z0-9]*)
      case "$RELEASE_VERSION" in *[!A-Za-z0-9._-]*|*..*)
        fail_integrity "release version не встроена или небезопасна."
        ;;
      esac
      ;;
    *)
      fail_integrity "release version не встроена или небезопасна."
      ;;
  esac
  case "$ARCHIVE_URL" in
    https://*) ;;
    *) fail_integrity "release URL должен быть встроенным HTTPS URL." ;;
  esac
  case "$ARCHIVE_SHA256" in
    *[!A-Fa-f0-9]*|"")
      fail_integrity "archive SHA-256 не встроен."
      ;;
  esac
  [ "${#ARCHIVE_SHA256}" -eq 64 ] ||
    fail_integrity "archive SHA-256 имеет неверную длину."
}

verify_self() {
  local expected actual
  expected="${VIBE_MAC_SHA256:-}"
  case "$expected" in
    *[!A-Fa-f0-9]*|"")
      fail_integrity "bootstrap SHA-256 не передан trust loader-ом."
      ;;
  esac
  [ "${#expected}" -eq 64 ] ||
    fail_integrity "bootstrap SHA-256 имеет неверную длину."
  [ -f "$0" ] && [ ! -L "$0" ] ||
    fail_integrity "bootstrap должен быть обычным файлом."
  actual="$(sha256_file_standalone "$0")"
  [ "$actual" = "$expected" ] ||
    fail_integrity "bootstrap SHA-256 не совпал."
}

download_archive() {
  local curl_bin attempt status
  if [ "${VIBE_MAC_TEST_MODE:-0}" = 1 ]; then
    curl_bin="${VIBE_MAC_CURL_BIN:?test curl не задан}"
  else
    curl_bin=/usr/bin/curl
  fi
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if "$curl_bin" \
      --proto '=https' \
      --tlsv1.2 \
      --fail \
      --location \
      --silent \
      --show-error \
      --connect-timeout 15 \
      --max-time 300 \
      --output "$1" \
      "$ARCHIVE_URL"; then
      return 0
    else
      status="$?"
    fi
    [ "$attempt" -lt 3 ] || return "$status"
    if [ "${VIBE_MAC_TEST_MODE:-0}" != 1 ]; then
      /bin/sleep "$attempt"
    fi
    attempt=$((attempt + 1))
  done
}

validate_archive_names() {
  local listing expected line
  listing="$1"
  expected="vibe-mac-$RELEASE_VERSION"
  [ -s "$listing" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || return 1
    case "$line" in
      /*|*\\*|*"/../"*|*"/./"*|*"//"*) return 1 ;;
    esac
    if printf '%s' "$line" |
      LC_ALL=C /usr/bin/grep -Eq '[[:cntrl:]]'; then
      return 1
    fi
    if ! printf '%s\n' "$line" |
      LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9._/@+-]+/?$'; then
      return 1
    fi
    case "$line" in
      "$expected"|"$expected/"|"$expected/"*) ;;
      *) return 1 ;;
    esac
  done <"$listing"
}

validate_archive() {
  local archive listing verbose
  archive="$1"
  listing="$TEMP_DIR/archive.list"
  verbose="$TEMP_DIR/archive.verbose"
  if ! /usr/bin/tar -tzf "$archive" >"$listing" 2>/dev/null; then
    fail_integrity "release archive повреждён или truncated."
  fi
  validate_archive_names "$listing" ||
    fail_integrity "release archive содержит небезопасный path/top-level."
  if LC_ALL=C /usr/bin/sort "$listing" |
    /usr/bin/uniq -d | /usr/bin/grep -q .; then
    fail_integrity "release archive содержит duplicate entries."
  fi
  if ! /usr/bin/tar -tvzf "$archive" >"$verbose" 2>/dev/null; then
    fail_integrity "не удалось проверить типы archive entries."
  fi
  if LC_ALL=C /usr/bin/grep -Eq '^[^-d]' "$verbose"; then
    fail_integrity "link/special entries в release archive запрещены."
  fi
}

validate_extracted_bundle() {
  local root entry
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] ||
    fail_integrity "ожидаемый release root отсутствует."
  if /usr/bin/find "$root" -type l -print -quit | /usr/bin/grep -q .; then
    fail_integrity "после распаковки обнаружен symlink."
  fi
  if /usr/bin/find "$root" ! -type f ! -type d -print -quit |
    /usr/bin/grep -q .; then
    fail_integrity "после распаковки обнаружен special node."
  fi
  for entry in install.sh verify.sh doctor.sh uninstall.sh; do
    [ -f "$root/$entry" ] &&
      [ ! -L "$root/$entry" ] &&
      [ -x "$root/$entry" ] ||
      fail_integrity "в bundle отсутствует executable $entry."
  done
  [ -f "$root/config/versions.env" ] &&
    [ ! -L "$root/config/versions.env" ] ||
    fail_integrity "в bundle отсутствует config/versions.env."
}

file_mode_standalone() {
  if /usr/bin/stat -f '%Lp' "$1" >/dev/null 2>&1; then
    /usr/bin/stat -f '%Lp' "$1"
  else
    /usr/bin/stat -c '%a' "$1"
  fi
}

tree_sha256_standalone() {
  local root
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  (
    cd "$root"
    /usr/bin/find . -mindepth 1 \
      ! -name .bundle-sha256 \
      ! -name .bundle-tree-sha256 \
      -print | LC_ALL=C /usr/bin/sort |
      while IFS= read -r path; do
        case "$path" in *$'\n'*|*$'\r'*) exit 2 ;; esac
        if [ -L "$path" ]; then
          exit 2
        elif [ -f "$path" ]; then
          printf 'F\t%s\t%s\t%s\n' \
            "$(file_mode_standalone "$path")" \
            "$(sha256_file_standalone "$path")" \
            "$path"
        elif [ -d "$path" ]; then
          printf 'D\t%s\t-\t%s\n' \
            "$(file_mode_standalone "$path")" "$path"
        else
          exit 2
        fi
      done
  ) | sha256_stdin_standalone
}

install_release() {
  local extracted destination archive_marker tree_marker actual_tree
  extracted="$1"
  destination="$VIBE_MAC_RUNTIME_ROOT/releases/$RELEASE_VERSION"
  archive_marker="$destination/.bundle-sha256"
  tree_marker="$destination/.bundle-tree-sha256"

  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ -L "$destination" ] || [ ! -d "$destination" ] ||
      [ ! -f "$archive_marker" ] || [ -L "$archive_marker" ] ||
      [ ! -f "$tree_marker" ] || [ -L "$tree_marker" ] ||
      [ "$(/bin/cat "$archive_marker")" != "$ARCHIVE_SHA256" ] ||
      [ "$(/bin/cat "$tree_marker")" != "$RELEASE_TREE_SHA" ]; then
      fail_integrity "существующий release не совпадает с archive SHA."
    fi
    actual_tree="$(tree_sha256_standalone "$destination")" ||
      fail_integrity "существующий release нельзя безопасно проверить."
    [ "$actual_tree" = "$RELEASE_TREE_SHA" ] ||
      fail_integrity "существующий release изменён после установки."
    return 0
  fi

  INCOMING_DIR="$(/usr/bin/mktemp -d \
    "$VIBE_MAC_RUNTIME_ROOT/releases/.incoming-$RELEASE_VERSION.XXXXXX")"
  /bin/chmod 0700 "$INCOMING_DIR"
  /bin/cp -Rp "$extracted/." "$INCOMING_DIR"
  actual_tree="$(tree_sha256_standalone "$INCOMING_DIR")" ||
    fail_integrity "incoming release нельзя безопасно проверить."
  [ "$actual_tree" = "$RELEASE_TREE_SHA" ] ||
    fail_integrity "incoming release fingerprint не совпал."
  printf '%s\n' "$ARCHIVE_SHA256" >"$INCOMING_DIR/.bundle-sha256"
  printf '%s\n' "$RELEASE_TREE_SHA" >"$INCOMING_DIR/.bundle-tree-sha256"
  /bin/chmod 0600 \
    "$INCOMING_DIR/.bundle-sha256" \
    "$INCOMING_DIR/.bundle-tree-sha256"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    fail_integrity "release destination появился во время установки."
  fi
  /bin/mv "$INCOMING_DIR" "$destination"
  INCOMING_DIR=
}

preflight_current() {
  local current existing version
  current="$VIBE_MAC_RUNTIME_ROOT/current"
  if [ ! -e "$current" ] && [ ! -L "$current" ]; then
    return 0
  fi
  [ -L "$current" ] ||
    fail_integrity "current занят не symlink."
  existing="$(/usr/bin/readlink "$current")" ||
    fail_integrity "существующий current не читается."
  case "$existing" in releases/*) ;; *)
    fail_integrity "существующий current выходит за allowlist."
    ;;
  esac
  version="${existing#releases/}"
  case "$version" in
    [A-Za-z0-9]*)
      case "$version" in *[!A-Za-z0-9._-]*|*..*)
        fail_integrity "существующий current небезопасен."
        ;;
      esac
      ;;
    *) fail_integrity "существующий current небезопасен." ;;
  esac
  [ "$existing" = "releases/$version" ] ||
    fail_integrity "существующий current содержит extra path."
  [ -d "$VIBE_MAC_RUNTIME_ROOT/$existing" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$existing" ] ||
    fail_integrity "существующий current dangling или небезопасен."
}

activate_current() {
  local current temp target existing version
  current="$VIBE_MAC_RUNTIME_ROOT/current"
  temp="$VIBE_MAC_RUNTIME_ROOT/.current.vibe-mac.$$"
  target="releases/$RELEASE_VERSION"
  if [ -e "$current" ] && [ ! -L "$current" ]; then
    fail_integrity "current занят не symlink."
  fi
  if [ -L "$current" ]; then
    existing="$(/usr/bin/readlink "$current")" ||
      fail_integrity "существующий current не читается."
    case "$existing" in releases/*) ;; *)
      fail_integrity "существующий current выходит за allowlist."
      ;;
    esac
    version="${existing#releases/}"
    case "$version" in
      [A-Za-z0-9]*)
        case "$version" in *[!A-Za-z0-9._-]*|*..*)
          fail_integrity "существующий current небезопасен."
          ;;
        esac
        ;;
      *) fail_integrity "существующий current небезопасен." ;;
    esac
    [ "$existing" = "releases/$version" ] ||
      fail_integrity "существующий current содержит extra path."
    [ -d "$VIBE_MAC_RUNTIME_ROOT/$existing" ] &&
      [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$existing" ] ||
      fail_integrity "существующий current dangling или небезопасен."
    VIBE_MAC_PREVIOUS_RELEASE_VERSION="$version"
    export VIBE_MAC_PREVIOUS_RELEASE_VERSION
  fi
  if [ -e "$temp" ] || [ -L "$temp" ]; then
    fail_integrity "atomic current temp уже существует."
  fi
  /bin/ln -s "$target" "$temp"
  if [ "${VIBE_MAC_TEST_MODE:-0}" = 1 ] &&
    [ "${VIBE_MAC_TEST_FAILPOINT:-}" = before-current-swap ]; then
    /bin/unlink "$temp"
    fail_operation "injected failure before current swap."
  fi
  /bin/mv -f "$temp" "$current"
}

render_launcher() {
  local target
  target="$1"
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'root="$HOME/.vibe-mac"'
  printf '%s\n' 'current="$root/current"'
  printf '%s\n' '[ -L "$current" ] || { printf "Ошибка: current небезопасен.\\n" >&2; exit 2; }'
  printf '%s\n' 'link="$(/usr/bin/readlink "$current")"'
  printf '%s\n' 'case "$link" in releases/*) ;; *) printf "Ошибка: current вне allowlist.\\n" >&2; exit 2 ;; esac'
  printf '%s\n' 'version="${link#releases/}"'
  printf '%s\n' 'case "$version" in [A-Za-z0-9]*) ;; *) exit 2 ;; esac'
  printf '%s\n' 'case "$version" in *[!A-Za-z0-9._-]*|*..*) exit 2 ;; esac'
  printf '%s\n' '[ "$link" = "releases/$version" ] || exit 2'
  printf '%s\n' 'release="$root/$link"'
  printf '%s\n' '[ -d "$release" ] && [ ! -L "$release" ] || exit 2'
  printf 'target="$release/%s.sh"\n' "$target"
  printf '%s\n' '[ -f "$target" ] && [ ! -L "$target" ] || {'
  printf '%s\n' '  printf "Ошибка: установленный vibe-mac bundle повреждён.\\n" >&2'
  printf '%s\n' '  exit 2'
  printf '%s\n' '}'
  printf '%s\n' 'exec /bin/bash "$target" "$@"'
}

preflight_launcher() {
  local name target destination expected
  name="$1"
  target="$2"
  destination="$VIBE_MAC_RUNTIME_ROOT/bin/$name"
  expected="$TEMP_DIR/launcher-$name"
  render_launcher "$target" >"$expected"
  /bin/chmod 0700 "$expected"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -f "$destination" ] || [ -L "$destination" ] ||
      ! /usr/bin/cmp -s "$expected" "$destination"; then
      fail_integrity "launcher $name уже занят другим содержимым."
    fi
  fi
}

write_launcher() {
  local name destination expected temp
  name="$1"
  destination="$VIBE_MAC_RUNTIME_ROOT/bin/$name"
  expected="$TEMP_DIR/launcher-$name"
  if [ ! -f "$expected" ] || [ -L "$expected" ]; then
    fail_integrity "launcher $name не прошёл preflight."
  fi
  if [ -f "$destination" ] && [ ! -L "$destination" ]; then
    return 0
  fi
  temp="$VIBE_MAC_RUNTIME_ROOT/bin/.$name.vibe-mac.$$"
  /bin/cp "$expected" "$temp"
  /bin/chmod 0700 "$temp"
  /bin/mv -f "$temp" "$destination"
}

prepare_runtime_layout() {
  local path
  if [ -L "$VIBE_MAC_RUNTIME_ROOT" ] ||
    { [ -e "$VIBE_MAC_RUNTIME_ROOT" ] &&
      [ ! -d "$VIBE_MAC_RUNTIME_ROOT" ]; }; then
    fail_integrity "runtime root небезопасен."
  fi
  /bin/mkdir -p "$VIBE_MAC_RUNTIME_ROOT"
  for path in \
    "$VIBE_MAC_RUNTIME_ROOT/releases" \
    "$VIBE_MAC_RUNTIME_ROOT/bin"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
      fail_integrity "runtime child небезопасен: $path."
    fi
    /bin/mkdir -p "$path"
  done
  /bin/chmod 0700 \
    "$VIBE_MAC_RUNTIME_ROOT" \
    "$VIBE_MAC_RUNTIME_ROOT/releases" \
    "$VIBE_MAC_RUNTIME_ROOT/bin"
}

DRY_RUN="${DRY_RUN:-0}"
validate_bool_standalone DRY_RUN "$DRY_RUN"
validate_bool_standalone VIBE_MAC_TEST_MODE "${VIBE_MAC_TEST_MODE:-0}"

if [ "$DRY_RUN" = 1 ]; then
  printf '%s\n' \
    "DRY_RUN: bootstrap только показывает статический план." \
    "План: проверить self/archive SHA, безопасно распаковать versioned bundle," \
    "атомарно переключить current и запустить install.sh." \
    "Сеть, temp и $HOME/.vibe-mac не затронуты."
  exit 0
fi

configure_release_values
verify_self

if [ "${VIBE_MAC_TEST_MODE:-0}" = 1 ]; then
  VIBE_MAC_RUNTIME_ROOT="${VIBE_MAC_RUNTIME_ROOT:?test runtime root не задан}"
else
  VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
fi
export VIBE_MAC_RUNTIME_ROOT

umask 077
TEMP_DIR="$(/usr/bin/mktemp -d \
  "${TMPDIR:-/tmp}/vibe-mac.bootstrap.XXXXXX")"
/bin/chmod 0700 "$TEMP_DIR"
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

archive="$TEMP_DIR/release.tar.gz"
download_archive "$archive" ||
  fail_integrity "release archive не удалось скачать."
[ "$(sha256_file_standalone "$archive")" = "$ARCHIVE_SHA256" ] ||
  fail_integrity "release archive SHA-256 не совпал."
validate_archive "$archive"

extract_dir="$TEMP_DIR/extracted"
/bin/mkdir "$extract_dir"
if ! /usr/bin/tar -xzf "$archive" -C "$extract_dir" 2>/dev/null; then
  fail_integrity "release archive не удалось распаковать."
fi
extracted="$extract_dir/vibe-mac-$RELEASE_VERSION"
validate_extracted_bundle "$extracted"
RELEASE_TREE_SHA="$(tree_sha256_standalone "$extracted")" ||
  fail_integrity "не удалось вычислить release tree fingerprint."

prepare_runtime_layout
install_release "$extracted"
preflight_current
preflight_launcher vibe-mac-verify verify
preflight_launcher vibe-mac-doctor doctor
preflight_launcher vibe-mac-uninstall uninstall
write_launcher vibe-mac-verify verify
write_launcher vibe-mac-doctor doctor
write_launcher vibe-mac-uninstall uninstall
activate_current

printf 'Установлен проверенный vibe-mac release %s.\n' "$RELEASE_VERSION"
if [ "${VIBE_MAC_TEST_MODE:-0}" = 1 ] &&
  [ "${VIBE_MAC_BOOTSTRAP_NO_EXEC:-0}" = 1 ]; then
  exit 0
fi

export VIBE_MAC_RELEASE_VERSION="$RELEASE_VERSION"
export VIBE_MAC_RELEASE_ARCHIVE_SHA256="$ARCHIVE_SHA256"
export VIBE_MAC_RELEASE_TREE_SHA256="$RELEASE_TREE_SHA"
VIBE_MAC_LAUNCHER_VERIFY_SHA256="$(sha256_file_standalone \
  "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify")"
VIBE_MAC_LAUNCHER_DOCTOR_SHA256="$(sha256_file_standalone \
  "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor")"
VIBE_MAC_LAUNCHER_UNINSTALL_SHA256="$(sha256_file_standalone \
  "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-uninstall")"
export VIBE_MAC_LAUNCHER_VERIFY_SHA256
export VIBE_MAC_LAUNCHER_DOCTOR_SHA256
export VIBE_MAC_LAUNCHER_UNINSTALL_SHA256
cleanup
TEMP_DIR=
trap - EXIT
exec /bin/bash "$VIBE_MAC_RUNTIME_ROOT/current/install.sh"
