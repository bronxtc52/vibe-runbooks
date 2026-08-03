#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(/bin/realpath "$0" 2>/dev/null)" || {
  /usr/bin/printf '%s\n' 'Ошибка: uninstall.sh path нельзя канонизировать.' >&2
  exit 2
}
case "$SCRIPT_PATH" in
  /*/*) SCRIPT_DIR="${SCRIPT_PATH%/*}" ;;
  *)
    /usr/bin/printf '%s\n' 'Ошибка: uninstall.sh path небезопасен.' >&2
    exit 2
    ;;
esac
VIBE_MAC_ROOT="$SCRIPT_DIR"
export VIBE_MAC_ROOT

# `git archive` replaces this literal with the exact release commit. Source
# checkouts retain test seams; packaged normal execution validates the active
# release before sourcing any release-controlled file.
# shellcheck disable=SC2016
VIBE_MAC_UNINSTALL_BUILD_COMMIT='$Format:%H$'
# shellcheck disable=SC2016
VIBE_MAC_UNINSTALL_SOURCE_MARKER='$''Format:%H$'
case "$VIBE_MAC_UNINSTALL_BUILD_COMMIT" in
  "$VIBE_MAC_UNINSTALL_SOURCE_MARKER")
    VIBE_MAC_UNINSTALL_BUILD_KIND=source
    ;;
  *)
    if [ "${#VIBE_MAC_UNINSTALL_BUILD_COMMIT}" -ne 40 ] ||
      ! printf '%s\n' "$VIBE_MAC_UNINSTALL_BUILD_COMMIT" |
      LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{40}$'; then
      printf '%s\n' 'Ошибка: неизвестный build marker uninstall.sh.' >&2
      exit 2
    fi
    VIBE_MAC_UNINSTALL_BUILD_KIND=release
    VIBE_MAC_TEST_MODE=0
    export VIBE_MAC_TEST_MODE
    ;;
esac
readonly VIBE_MAC_UNINSTALL_BUILD_COMMIT VIBE_MAC_UNINSTALL_SOURCE_MARKER
readonly VIBE_MAC_UNINSTALL_BUILD_KIND

uninstall_entrypoint_integrity_fail() {
  printf 'Ошибка: active release vibe-mac повреждён: %s\n' "$1" >&2
  exit 2
}

uninstall_entrypoint_file_mode() {
  if /usr/bin/stat -f '%Lp' "$1" >/dev/null 2>&1; then
    /usr/bin/stat -f '%Lp' "$1"
  else
    /usr/bin/stat -c '%a' "$1"
  fi
}

uninstall_entrypoint_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

uninstall_entrypoint_sha256_stdin() {
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

uninstall_entrypoint_sha_marker() {
  local marker value
  marker="$1"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  value="$(/bin/cat "$marker")" || return 2
  [ "${#value}" -eq 64 ] || return 2
  case "$value" in *[!0-9a-f]*) return 2 ;; esac
  printf '%s\n' "$value"
}

uninstall_entrypoint_release_tree_sha256() {
  local root absolute path control_status mode file_sha
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  /usr/bin/find "$root" -mindepth 1 -print0 |
      while IFS= read -r -d '' absolute; do
        case "$absolute" in
          "$root"/*) path=".${absolute#"$root"}" ;;
          *) exit 2 ;;
        esac
        control_status=0
        printf '%s' "$path" |
          LC_ALL=C /usr/bin/grep -Eq '[[:cntrl:]]' || control_status="$?"
        case "$control_status" in
          0) exit 2 ;;
          1) ;;
          *) exit 2 ;;
        esac
        case "$path" in
          ./*) ;;
          *) exit 2 ;;
        esac
        case "$path" in
          *\\*|*"/../"*|*"/./"*|*"//"*) exit 2 ;;
        esac
        if [ -L "$absolute" ]; then
          exit 2
        elif [ -f "$absolute" ]; then
          :
        elif [ -d "$absolute" ]; then
          :
        else
          exit 2
        fi
        case "$path" in
          ./.bundle-sha256|./.bundle-tree-sha256) continue ;;
        esac
        printf '%s\n' "$path"
      done |
      LC_ALL=C /usr/bin/sort |
      while IFS= read -r path; do
        absolute="$root/${path#./}"
        if [ -L "$absolute" ]; then
          exit 2
        elif [ -f "$absolute" ]; then
          mode="$(uninstall_entrypoint_file_mode "$absolute")" || exit 2
          file_sha="$(uninstall_entrypoint_sha256_file "$absolute")" || exit 2
          printf 'F\t%s\t%s\t%s\n' \
            "$mode" "$file_sha" "$path"
        elif [ -d "$absolute" ]; then
          mode="$(uninstall_entrypoint_file_mode "$absolute")" || exit 2
          printf 'D\t%s\t-\t%s\n' "$mode" "$path"
        else
          exit 2
        fi
      done |
      uninstall_entrypoint_sha256_stdin
}

uninstall_entrypoint_verify_active_release() {
  local home_physical runtime releases current target version release
  local runtime_physical releases_physical release_physical
  local archive_sha expected_tree actual_tree control_status

  case "${HOME:-}" in
    /*) ;;
    *) uninstall_entrypoint_integrity_fail 'HOME должен быть absolute path.' ;;
  esac
  control_status=0
  printf '%s' "$HOME" |
    LC_ALL=C /usr/bin/grep -Eq '[[:cntrl:]]' || control_status="$?"
  case "$control_status" in
    0)
      uninstall_entrypoint_integrity_fail 'HOME содержит control character.'
      ;;
    1) ;;
    *) uninstall_entrypoint_integrity_fail 'HOME нельзя проверить.' ;;
  esac
  [ -d "$HOME" ] && [ ! -L "$HOME" ] ||
    uninstall_entrypoint_integrity_fail 'HOME отсутствует или является symlink.'
  home_physical="$(/bin/realpath "$HOME" 2>/dev/null)" ||
    uninstall_entrypoint_integrity_fail 'HOME нельзя канонизировать.'
  [ "$HOME" = "$home_physical" ] ||
    uninstall_entrypoint_integrity_fail 'HOME содержит symlink или dot segment.'

  runtime="$HOME/.vibe-mac"
  releases="$runtime/releases"
  current="$runtime/current"
  [ -d "$runtime" ] && [ ! -L "$runtime" ] ||
    uninstall_entrypoint_integrity_fail 'runtime root небезопасен.'
  runtime_physical="$(/bin/realpath "$runtime" 2>/dev/null)" ||
    uninstall_entrypoint_integrity_fail 'runtime root нельзя канонизировать.'
  [ "$runtime_physical" = "$home_physical/.vibe-mac" ] ||
    uninstall_entrypoint_integrity_fail 'runtime root вышел за HOME.'
  [ -d "$releases" ] && [ ! -L "$releases" ] ||
    uninstall_entrypoint_integrity_fail 'releases небезопасен.'
  releases_physical="$(/bin/realpath "$releases" 2>/dev/null)" ||
    uninstall_entrypoint_integrity_fail 'releases нельзя канонизировать.'
  [ "$releases_physical" = "$runtime_physical/releases" ] ||
    uninstall_entrypoint_integrity_fail 'releases вышел за runtime root.'

  [ -L "$current" ] ||
    uninstall_entrypoint_integrity_fail 'current должен быть symlink.'
  target="$(/usr/bin/readlink "$current")" ||
    uninstall_entrypoint_integrity_fail 'current не читается.'
  case "$target" in
    releases/[A-Za-z0-9]*)
      version="${target#releases/}"
      case "$version" in
        *[!A-Za-z0-9._-]*|*..*)
          uninstall_entrypoint_integrity_fail \
            'current содержит небезопасную версию.'
          ;;
      esac
      ;;
    *)
      uninstall_entrypoint_integrity_fail \
        'current должен указывать на releases/<version>.'
      ;;
  esac
  [ "$target" = "releases/$version" ] ||
    uninstall_entrypoint_integrity_fail 'current содержит extra path.'

  release="$runtime/$target"
  [ -d "$release" ] && [ ! -L "$release" ] ||
    uninstall_entrypoint_integrity_fail 'active release небезопасен.'
  release_physical="$(/bin/realpath "$release" 2>/dev/null)" ||
    uninstall_entrypoint_integrity_fail 'active release нельзя канонизировать.'
  [ "$release_physical" = "$releases_physical/$version" ] ||
    uninstall_entrypoint_integrity_fail 'active release вышел за releases.'
  [ "$SCRIPT_DIR" = "$release_physical" ] ||
    uninstall_entrypoint_integrity_fail \
      'uninstall.sh запущен не из active release.'

  archive_sha="$(uninstall_entrypoint_sha_marker \
    "$release/.bundle-sha256")" ||
    uninstall_entrypoint_integrity_fail '.bundle-sha256 malformed.'
  [ -n "$archive_sha" ] ||
    uninstall_entrypoint_integrity_fail '.bundle-sha256 пуст.'
  expected_tree="$(uninstall_entrypoint_sha_marker \
    "$release/.bundle-tree-sha256")" ||
    uninstall_entrypoint_integrity_fail '.bundle-tree-sha256 malformed.'
  actual_tree="$(uninstall_entrypoint_release_tree_sha256 "$release")" ||
    uninstall_entrypoint_integrity_fail 'release tree небезопасен.'
  [ "$actual_tree" = "$expected_tree" ] ||
    uninstall_entrypoint_integrity_fail 'release tree fingerprint не совпал.'
}

INTERNAL_APPLY=0

uninstall_early_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

uninstall_valid_sha256() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

uninstall_temp_parent() {
  local parent
  parent=/tmp
  if [ "${VIBE_MAC_TEST_MODE:-0}" = 1 ] &&
    [ "${VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR:-0}" != 1 ]; then
    parent="${TMPDIR:-/tmp}"
  fi
  [ -d "$parent" ] || return 2
  /bin/realpath "$parent" 2>/dev/null
}

uninstall_temp_path_allowed() {
  local root parent prefix suffix
  root="$1"
  parent="$(uninstall_temp_parent)" || return 2
  prefix="$parent/vibe-mac-uninstall."
  case "$root" in
    "$prefix"*) ;;
    *) return 2 ;;
  esac
  suffix="${root#"$prefix"}"
  case "$suffix" in
    ""|*/*|*[!A-Za-z0-9]*) return 2 ;;
  esac
}

validate_uninstall_runtime() {
  local root expected_manifest actual_manifest
  local absolute relative expected actual symlinks
  root="$1"
  expected_manifest="$2"
  uninstall_temp_path_allowed "$root" || return 2
  uninstall_valid_sha256 "$expected_manifest" || return 2
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  [ -d "$root/config" ] && [ ! -L "$root/config" ] || return 2
  [ -d "$root/lib" ] && [ ! -L "$root/lib" ] || return 2
  [ -f "$root/.runtime-sha256" ] &&
    [ ! -L "$root/.runtime-sha256" ] || return 2
  for relative in \
    uninstall.sh \
    config/versions.env \
    lib/guard.sh \
    lib/ui.sh \
    lib/util.sh; do
    [ -f "$root/$relative" ] && [ ! -L "$root/$relative" ] || return 2
  done
  actual_manifest="$(uninstall_early_sha256_file \
    "$root/.runtime-sha256")" || return 2
  [ "$actual_manifest" = "$expected_manifest" ] || return 2

  if ! /usr/bin/awk '
    function valid_sha(value) {
      return length(value) == 64 && value !~ /[^0-9a-f]/
    }
    NF != 2 || !valid_sha($1) { exit 1 }
    NR == 1 && $2 != "uninstall.sh" { exit 1 }
    NR == 2 && $2 != "config/versions.env" { exit 1 }
    NR == 3 && $2 != "lib/guard.sh" { exit 1 }
    NR == 4 && $2 != "lib/ui.sh" { exit 1 }
    NR == 5 && $2 != "lib/util.sh" { exit 1 }
    END { if (NR != 5) exit 1 }
  ' "$root/.runtime-sha256"; then
    return 2
  fi

  if ! /usr/bin/find "$root" -mindepth 1 -print0 |
    while IFS= read -r -d '' absolute; do
      case "$absolute" in
        "$root/.runtime-sha256" | \
        "$root/config" | \
        "$root/config/versions.env" | \
        "$root/lib" | \
        "$root/lib/guard.sh" | \
        "$root/lib/ui.sh" | \
        "$root/lib/util.sh" | \
        "$root/uninstall.sh") ;;
        *) exit 2 ;;
      esac
    done; then
    return 2
  fi
  symlinks="$(/usr/bin/find "$root" -type l -print -quit)" || return 2
  [ -z "$symlinks" ] || return 2
  while read -r expected relative; do
    actual="$(uninstall_early_sha256_file "$root/$relative")" || return 2
    [ "$actual" = "$expected" ] || return 2
  done <"$root/.runtime-sha256"
}

if [ "${1:-}" = --internal-apply ]; then
  if ! validate_uninstall_runtime \
    "$SCRIPT_DIR" \
    "${VIBE_MAC_UNINSTALL_RUNTIME_MANIFEST_SHA256:-}"; then
    printf '%s\n' \
      'Ошибка: internal uninstall runtime не прошёл integrity-проверку.' \
      >&2
    exit 2
  fi
  INTERNAL_APPLY=1
elif [ "$VIBE_MAC_UNINSTALL_BUILD_KIND" = release ]; then
  uninstall_entrypoint_verify_active_release
fi

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

APPLY=0
CONFLICTS=0
RELEASE_STATE=none
RELEASE_VERSION=
RELEASE_PATH=
UNINSTALL_TEMP=
UNINSTALL_RUNTIME_MANIFEST_SHA256=
BREW_BIN=
GIT_BIN=
MISE_BIN=
PRESERVE_MISE=0

step_expected_homebrew_prefix() {
  if is_test_mode &&
    [ -n "${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" ]; then
    case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
      /*)
        case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
          *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;;
        esac
        printf '%s\n' "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX"
        return 0
        ;;
      *) return 2 ;;
    esac
  fi
  expected_homebrew_prefix
}

destructive_homebrew_executable() {
  local name prefix bin candidate_path candidate status
  name="$1"
  case "$name" in brew|git|mise) ;; *) return 2 ;; esac
  prefix="$(step_expected_homebrew_prefix)" || return 2
  bin="$prefix/bin"
  candidate_path="$bin/$name"
  homebrew_env_files_safe "$prefix" || return 2
  if [ ! -e "$prefix" ] && [ ! -L "$prefix" ]; then
    return 1
  fi
  [ -d "$prefix" ] && [ ! -L "$prefix" ] || return 2
  if [ ! -e "$bin" ] && [ ! -L "$bin" ]; then
    return 1
  fi
  [ -d "$bin" ] && [ ! -L "$bin" ] || return 2
  if [ ! -e "$candidate_path" ] && [ ! -L "$candidate_path" ]; then
    return 1
  fi
  status=0
  candidate="$(homebrew_executable_in_prefix "$prefix" "$name")" ||
    status="$?"
  if [ "$status" -eq 1 ] && [ -L "$candidate_path" ]; then
    status=2
  fi
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$candidate"
}

uninstall_brew_run() {
  local prefix clean_path run_user clean_tmp config_home
  [ -n "$BREW_BIN" ] || return 2
  prefix="$(step_expected_homebrew_prefix)" || return 2
  homebrew_env_files_safe "$prefix" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  clean_tmp=/tmp
  config_home=/var/empty
  [ -d "$config_home" ] && [ ! -L "$config_home" ] || return 2

  if is_test_mode; then
    if [ "${VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR:-0}" != 1 ]; then
      clean_tmp="${TMPDIR:-/tmp}"
    fi
    /usr/bin/env -i \
      HOME="$HOME" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      PATH="$clean_path" \
      TMPDIR="$clean_tmp" \
      LANG=C \
      LC_ALL=C \
      HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_INSTALL_UPGRADE=1 \
      HOMEBREW_NO_INSTALL_CLEANUP=1 \
      HOMEBREW_NO_ENV_HINTS=1 \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      CURL_HOME="$config_home" \
      XDG_CONFIG_HOME="$config_home" \
      TEST_ROOT="${TEST_ROOT:-}" \
      VIBE_MAC_ROOT="$VIBE_MAC_ROOT" \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      VIBE_MAC_BREW_STATE="${VIBE_MAC_BREW_STATE:-}" \
      VIBE_MAC_OWNED_VERSION="${VIBE_MAC_OWNED_VERSION:-}" \
      VIBE_MAC_TEST_BREW_USES_FAIL="${VIBE_MAC_TEST_BREW_USES_FAIL:-0}" \
      VIBE_MAC_TEST_BREW_DEPENDENT="${VIBE_MAC_TEST_BREW_DEPENDENT:-0}" \
      VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$prefix" \
      "$BREW_BIN" "$@"
    return
  fi

  /usr/bin/env -i \
    HOME="$HOME" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    PATH="$clean_path" \
    TMPDIR=/tmp \
    LANG=C \
    LC_ALL=C \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_INSTALL_UPGRADE=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    CURL_HOME="$config_home" \
    XDG_CONFIG_HOME="$config_home" \
    "$BREW_BIN" "$@"
}

uninstall_git_run() {
  local prefix clean_path run_user clean_tmp
  [ -n "$GIT_BIN" ] || return 2
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  clean_tmp=/tmp

  if is_test_mode; then
    if [ "${VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR:-0}" != 1 ]; then
      clean_tmp="${TMPDIR:-/tmp}"
    fi
    /usr/bin/env -i \
      HOME="$HOME" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      PATH="$clean_path" \
      TMPDIR="$clean_tmp" \
      LANG=C \
      LC_ALL=C \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      VIBE_MAC_GIT_STATE="${VIBE_MAC_GIT_STATE:-}" \
      "$GIT_BIN" "$@"
    return
  fi

  /usr/bin/env -i \
    HOME="$HOME" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    PATH="$clean_path" \
    TMPDIR="$clean_tmp" \
    LANG=C \
    LC_ALL=C \
    "$GIT_BIN" "$@"
}

uninstall_mise_run() {
  local prefix clean_path run_user clean_tmp trusted_config
  local data_dir cache_dir state_dir
  [ -n "$MISE_BIN" ] || return 2
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  clean_tmp=/tmp
  trusted_config="$VIBE_MAC_ROOT/config"
  data_dir="$HOME/.local/share/mise"
  cache_dir="$HOME/.cache/mise"
  state_dir="$HOME/.local/state/mise"
  [ -d "$trusted_config" ] && [ ! -L "$trusted_config" ] || return 2
  validate_home_dir_path "$data_dir" || return 2
  validate_home_dir_path "$cache_dir" || return 2
  validate_home_dir_path "$state_dir" || return 2

  if is_test_mode; then
    if [ "${VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR:-0}" != 1 ]; then
      clean_tmp="${TMPDIR:-/tmp}"
    fi
    /usr/bin/env -i \
      HOME="$HOME" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      PATH="$clean_path" \
      TMPDIR="$clean_tmp" \
      LANG=C \
      LC_ALL=C \
      MISE_YES=1 \
      MISE_CONFIG_DIR="$trusted_config" \
      MISE_GLOBAL_CONFIG_FILE=/dev/null \
      MISE_SYSTEM_CONFIG_FILE=/dev/null \
      MISE_DATA_DIR="$data_dir" \
      MISE_CACHE_DIR="$cache_dir" \
      MISE_STATE_DIR="$state_dir" \
      MISE_TMP_DIR="$clean_tmp" \
      TEST_ROOT="${TEST_ROOT:-}" \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      VIBE_MAC_MISE_STATE="${VIBE_MAC_MISE_STATE:-}" \
      VIBE_MAC_TEST_MISE_WHERE_OVERRIDE="${VIBE_MAC_TEST_MISE_WHERE_OVERRIDE:-}" \
      VIBE_MAC_TEST_MISE_VERSION_OVERRIDE="${VIBE_MAC_TEST_MISE_VERSION_OVERRIDE:-}" \
      VIBE_MAC_TEST_TRUSTED_CONFIG_DIR="$trusted_config" \
      "$MISE_BIN" -C "$trusted_config" "$@"
    return
  fi

  /usr/bin/env -i \
    HOME="$HOME" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    PATH="$clean_path" \
    TMPDIR="$clean_tmp" \
    LANG=C \
    LC_ALL=C \
    MISE_YES=1 \
    MISE_CONFIG_DIR="$trusted_config" \
    MISE_GLOBAL_CONFIG_FILE=/dev/null \
    MISE_SYSTEM_CONFIG_FILE=/dev/null \
    MISE_DATA_DIR="$data_dir" \
    MISE_CACHE_DIR="$cache_dir" \
    MISE_STATE_DIR="$state_dir" \
    MISE_TMP_DIR=/tmp \
    "$MISE_BIN" -C "$trusted_config" "$@"
}

usage() {
  printf '%s\n' \
    "Запуск: /bin/bash ./uninstall.sh [--dry-run|--apply]" \
    "Без флага выполняется только план. Apply требует typed UNINSTALL."
}

# Invoked through the EXIT trap installed immediately before temp creation.
# shellcheck disable=SC2329
cleanup_uninstall_temp() {
  local exit_code entries unexpected relative cleanup_failed
  exit_code="$?"
  [ -n "$UNINSTALL_TEMP" ] || return "$exit_code"
  if ! uninstall_temp_path_allowed "$UNINSTALL_TEMP" ||
    [ ! -d "$UNINSTALL_TEMP" ] || [ -L "$UNINSTALL_TEMP" ]; then
    printf '%s\n' \
      'Внимание: unsafe uninstall temp оставлен без удаления.' \
      >&2
    [ "$exit_code" -ne 0 ] || exit_code=2
    return "$exit_code"
  fi

  entries="$(
    cd "$UNINSTALL_TEMP" &&
      /usr/bin/find . -mindepth 1 -print | LC_ALL=C /usr/bin/sort
  )" || {
    [ "$exit_code" -ne 0 ] || exit_code=2
    return "$exit_code"
  }
  unexpected="$(printf '%s\n' "$entries" | /usr/bin/awk '
    $0 != "./.runtime-sha256" &&
    $0 != "./config" &&
    $0 != "./config/versions.env" &&
    $0 != "./lib" &&
    $0 != "./lib/guard.sh" &&
    $0 != "./lib/ui.sh" &&
    $0 != "./lib/util.sh" &&
    $0 != "./uninstall.sh" { print }
  ')"
  if [ -n "$unexpected" ] ||
    [ -n "$(/usr/bin/find "$UNINSTALL_TEMP" -type l -print -quit)" ]; then
    printf '%s\n' \
      'Внимание: uninstall temp содержит unexpected entries; оставляю его.' \
      >&2
    [ "$exit_code" -ne 0 ] || exit_code=2
    return "$exit_code"
  fi

  for relative in \
    .runtime-sha256 \
    config/versions.env \
    lib/guard.sh \
    lib/ui.sh \
    lib/util.sh \
    uninstall.sh; do
    if [ -e "$UNINSTALL_TEMP/$relative" ] ||
      [ -L "$UNINSTALL_TEMP/$relative" ]; then
      if [ ! -f "$UNINSTALL_TEMP/$relative" ] ||
        [ -L "$UNINSTALL_TEMP/$relative" ]; then
        printf 'Warning: unsafe temp entry preserved: %s\n' \
          "$UNINSTALL_TEMP/$relative" >&2
        [ "$exit_code" -ne 0 ] || exit_code=2
        return "$exit_code"
      fi
    fi
  done

  cleanup_failed=0
  for relative in \
    .runtime-sha256 \
    config/versions.env \
    lib/guard.sh \
    lib/ui.sh \
    lib/util.sh \
    uninstall.sh; do
    if [ -e "$UNINSTALL_TEMP/$relative" ]; then
      /bin/unlink "$UNINSTALL_TEMP/$relative" || cleanup_failed=1
    fi
  done
  for relative in config lib; do
    if [ -d "$UNINSTALL_TEMP/$relative" ]; then
      /bin/rmdir "$UNINSTALL_TEMP/$relative" || cleanup_failed=1
    fi
  done
  /bin/rmdir "$UNINSTALL_TEMP" || cleanup_failed=1
  UNINSTALL_TEMP=
  if [ "$cleanup_failed" -ne 0 ]; then
    printf '%s\n' 'Внимание: uninstall temp не удалён полностью.' >&2
    [ "$exit_code" -ne 0 ] || exit_code=2
  fi
  return "$exit_code"
}

formulae() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_UNINSTALL_FORMULAE:-}" ]; then
    printf '%s\n' "$VIBE_MAC_TEST_UNINSTALL_FORMULAE" | /usr/bin/tr ' ' '\n'
    return
  fi
  printf '%s\n' \
    git gh starship ripgrep fd fzf bat eza jq tree zoxide mise uv
}

casks() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_UNINSTALL_CASKS:-}" ]; then
    printf '%s\n' "$VIBE_MAC_TEST_UNINSTALL_CASKS" | /usr/bin/tr ' ' '\n'
    return
  fi
  printf '%s\n' \
    ghostty font-jetbrains-mono-nerd-font claude-code codex cursor cursor-cli \
    zed raycast visual-studio-code
}

defaults_tool() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_DEFAULTS_BIN:?test defaults не задан}"
  else
    printf '%s\n' /usr/bin/defaults
  fi
}

killall_tool() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_KILLALL_BIN:?test killall не задан}"
  else
    printf '%s\n' /usr/bin/killall
  fi
}

manifest_value() {
  json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "$1" 2>/dev/null
}

manifest_typed_value() {
  local keypath expected_type
  keypath="$1"
  expected_type="$2"
  plutil_run \
    -extract "$keypath" raw -expect "$expected_type" -- \
    "$VIBE_MAC_MANIFEST_FILE" 2>/dev/null
}

validate_manifest() {
  local schema installer_version install_id key
  if ! validate_home_dir_path "$VIBE_MAC_STATE_DIR"; then
    ui_fail "Runtime/state path содержит symlink или выходит из HOME."
    return 2
  fi
  if [ ! -f "$VIBE_MAC_MANIFEST_FILE" ] || [ -L "$VIBE_MAC_MANIFEST_FILE" ]; then
    ui_fail "Manifest отсутствует или является symlink; удаление заблокировано."
    return 2
  fi
  if ! json_lint "$VIBE_MAC_MANIFEST_FILE"; then
    ui_fail "Manifest повреждён; удаление заблокировано."
    return 2
  fi
  schema="$(manifest_typed_value schema_version integer)" || {
    ui_fail "Manifest schema_version имеет неверный тип."
    return 2
  }
  if [ "$schema" != "$MANIFEST_SCHEMA_VERSION" ]; then
    ui_fail "Неизвестная manifest schema: $schema."
    return 2
  fi
  installer_version="$(manifest_typed_value installer_version string)" || {
    ui_fail "Manifest installer_version имеет неверный тип."
    return 2
  }
  case "$installer_version" in
    ""|*[!A-Za-z0-9._-]*|*..*)
      ui_fail "Manifest installer_version имеет небезопасное значение."
      return 2
      ;;
  esac
  install_id="$(manifest_typed_value install_id string)" || {
    ui_fail "Manifest install_id имеет неверный тип."
    return 2
  }
  for key in \
    components packages files git_defaults defaults runtimes releases \
    current_link launchers; do
    if ! manifest_typed_value "$key" dictionary >/dev/null; then
      ui_fail "Manifest.$key должен быть dictionary."
      return 2
    fi
  done
}

validate_package_entry() {
  local kind name preexisting owned owner before after
  kind="$1"
  name="$2"
  if ! manifest_value "packages.$kind.$name" >/dev/null 2>&1; then
    return 0
  fi
  manifest_typed_value \
    "packages.$kind.$name" dictionary >/dev/null || return 2
  preexisting="$(manifest_typed_value \
    "packages.$kind.$name.preexisting" bool)" || return 2
  owned="$(manifest_typed_value \
    "packages.$kind.$name.owned" bool)" || return 2
  owner="$(manifest_typed_value \
    "packages.$kind.$name.owner" string)" || return 2
  before="$(manifest_typed_value \
    "packages.$kind.$name.version_before" string)" || return 2
  after="$(manifest_typed_value \
    "packages.$kind.$name.version_after" string)" || return 2
  case "$preexisting:$owned" in
    true:true|true:false|false:true|false:false) ;;
    *) return 2 ;;
  esac
  case "$owner" in homebrew|external|vibe-mac) ;; *) return 2 ;; esac
  printf '%s\n' "$before$after" |
    LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9@._+,: -]*$'
}

validate_packages() {
  local kind name names
  if ! manifest_typed_value packages dictionary >/dev/null ||
    ! manifest_typed_value packages.formulae dictionary >/dev/null ||
    ! manifest_typed_value packages.casks dictionary >/dev/null ||
    ! manifest_typed_value packages.dependency_delta array >/dev/null; then
    ui_fail "Manifest содержит небезопасную packages запись."
    return 2
  fi
  for kind in formulae casks; do
    if [ "$kind" = formulae ]; then
      names="$(formulae)"
    else
      names="$(casks)"
    fi
    for name in $names; do
      if ! validate_package_entry "$kind" "$name"; then
        ui_fail "Manifest содержит небезопасную package ownership запись."
        return 2
      fi
    done
  done
}

validate_file_entry() {
  manifest_validate_file_entry "$1" "$2" "$3" "$4" "$5"
}

validate_file_entries() {
  if ! manifest_typed_value files dictionary >/dev/null ||
    ! validate_file_entry \
    zprofile .zprofile managed_block zprofile zprofile ||
    ! validate_file_entry zshrc .zshrc managed_block zshrc zshrc ||
    ! validate_file_entry ghostty \
      "Library/Application Support/com.mitchellh.ghostty/config" \
      managed_block ghostty ghostty-config ||
    ! validate_file_entry aliases \
      .config/vibe-mac/aliases.zsh owned_file "" aliases-zsh ||
    ! validate_file_entry starship \
      .config/starship.toml owned_file "" starship-toml ||
    ! validate_file_entry mise-global \
      .config/mise/config.toml owned_file "" mise-global; then
    ui_fail "Manifest содержит небезопасную file ownership запись."
    return 2
  fi
}

uninstall_runtime_creation_proof_path() {
  local name install_id
  name="$1"
  case "$name" in node|python) ;; *) return 2 ;; esac
  install_id="$(manifest_typed_value install_id string)" || return 2
  validate_logical_id "$install_id" || return 2
  printf '%s/%s/runtime-%s.created\n' \
    "$VIBE_MAC_BACKUP_ROOT" "$install_id" "$name"
}

uninstall_runtime_creation_proof_matches() {
  local name version proof expected actual
  name="$1"
  version="$2"
  proof="$(uninstall_runtime_creation_proof_path "$name")" || return 2
  validate_home_dir_path "${proof%/*}" || return 2
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
  expected="$name|$version|.local/share/mise/installs/$name/$version"
  actual="$(/bin/cat "$proof")" || return 2
  [ "$actual" = "$expected" ]
}

validate_runtime_entry() {
  local name expected version preexisting owned target
  name="$1"
  expected="$2"
  manifest_typed_value "runtimes.$name" dictionary >/dev/null || return 2
  version="$(manifest_typed_value "runtimes.$name.version" string)" ||
    return 2
  preexisting="$(manifest_typed_value \
    "runtimes.$name.preexisting" bool)" || return 2
  owned="$(manifest_typed_value "runtimes.$name.owned" bool)" || return 2
  case "$preexisting:$owned" in
    true:false)
      [ "$version" = "$expected" ] || return 2
      ;;
    false:true)
      [ "$version" = "$expected" ] || return 2
      uninstall_runtime_creation_proof_matches "$name" "$expected" ||
        return 2
      ;;
    false:false)
      [ -z "$version" ] || [ "$version" = "$expected" ] || return 2
      ;;
    *)
      return 2
      ;;
  esac
  target="$HOME/.local/share/mise/installs/$name/$expected"
  validate_home_dir_path "$target"
}

validate_runtimes() {
  if ! manifest_typed_value runtimes dictionary >/dev/null ||
    ! validate_runtime_entry node "$NODE_VERSION" ||
    ! validate_runtime_entry python "$PYTHON_VERSION"; then
    ui_fail "Manifest содержит небезопасную runtime ownership запись."
    return 2
  fi
}

validate_git_default_entry() {
  local id expected_key expected_value key value created
  id="$1"
  expected_key="$2"
  expected_value="$3"
  if ! manifest_value "git_defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  manifest_typed_value \
    "git_defaults.$id" dictionary >/dev/null || return 2
  key="$(manifest_typed_value "git_defaults.$id.key" string)" || return 2
  value="$(manifest_typed_value \
    "git_defaults.$id.applied_value" string)" || return 2
  created="$(manifest_typed_value \
    "git_defaults.$id.created" bool)" || return 2
  [ "$key" = "$expected_key" ] &&
    [ "$value" = "$expected_value" ] &&
    [ "$created" = true ]
}

validate_git_defaults() {
  if ! manifest_typed_value git_defaults dictionary >/dev/null ||
    ! validate_git_default_entry \
    init-default-branch init.defaultBranch main ||
    ! validate_git_default_entry pull-rebase pull.rebase true ||
    ! validate_git_default_entry \
      push-auto-upstream push.autoSetupRemote true; then
    ui_fail "Manifest содержит небезопасную Git defaults запись."
    return 2
  fi
}

validate_default_entry() {
  local id expected_domain expected_key
  local domain key original_exists original_value applied_value
  id="$1"
  expected_domain="$2"
  expected_key="$3"
  if ! manifest_value "defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  manifest_typed_value "defaults.$id" dictionary >/dev/null || return 2
  domain="$(manifest_typed_value "defaults.$id.domain" string)" || return 2
  key="$(manifest_typed_value "defaults.$id.key" string)" || return 2
  original_exists="$(manifest_typed_value \
    "defaults.$id.original_exists" bool)" || return 2
  original_value="$(manifest_typed_value \
    "defaults.$id.original_value" bool)" || return 2
  applied_value="$(manifest_typed_value \
    "defaults.$id.applied_value" bool)" || return 2
  [ "$domain" = "$expected_domain" ] &&
    [ "$key" = "$expected_key" ] || return 2
  case "$original_exists:$original_value:$applied_value" in
    true:true:true|true:false:true|false:false:true) return 0 ;;
    *) return 2 ;;
  esac
}

validate_defaults() {
  if ! manifest_typed_value defaults dictionary >/dev/null ||
    ! validate_default_entry \
    dock_autohide com.apple.dock autohide ||
    ! validate_default_entry \
      finder_extensions NSGlobalDomain AppleShowAllExtensions; then
    ui_fail "Manifest содержит небезопасную macOS defaults запись."
    return 2
  fi
}

validate_omz_entry() {
  local owned preexisting tree version_before version_after
  manifest_typed_value components dictionary >/dev/null || return 2
  manifest_typed_value \
    components.oh_my_zsh dictionary >/dev/null || return 2
  owned="$(manifest_typed_value components.oh_my_zsh.owned bool)" || return 2
  preexisting="$(manifest_typed_value \
    components.oh_my_zsh.preexisting bool)" || return 2
  tree="$(manifest_typed_value \
    components.oh_my_zsh.tree_sha256 string)" || return 2
  version_before="$(manifest_typed_value \
    components.oh_my_zsh.version_before string)" || return 2
  version_after="$(manifest_typed_value \
    components.oh_my_zsh.version_after string)" || return 2
  if ! printf '%s\n' "$version_before$version_after" |
    LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9._+-]*$'; then
    return 2
  fi
  case "$owned:$preexisting" in
    false:false|false:true)
      [ -z "$tree" ] || validate_sha256_or_empty "$tree"
      ;;
    true:false)
      validate_sha256_or_empty "$tree" && [ -n "$tree" ]
      ;;
    *)
      return 2
      ;;
  esac
}

validate_release_entry() {
  local owned path_kind archive_sha tree_sha current_target slot field
  local launcher_id expected_path launcher_path_kind launcher_path
  local expected_sha actual_sha present missing target
  local actual_current archive_marker_value tree_marker_value actual_tree
  manifest_typed_value releases dictionary >/dev/null || return 2
  for slot in current previous; do
    manifest_typed_value "releases.$slot" dictionary >/dev/null || return 2
    for field in version path_kind path archive_sha256 tree_sha256; do
      manifest_typed_value \
        "releases.$slot.$field" string >/dev/null || return 2
    done
    manifest_typed_value "releases.$slot.owned" bool >/dev/null || return 2
  done
  manifest_typed_value current_link dictionary >/dev/null || return 2
  for field in path_kind path target; do
    manifest_typed_value "current_link.$field" string >/dev/null || return 2
  done
  manifest_typed_value current_link.owned bool >/dev/null || return 2
  manifest_typed_value launchers dictionary >/dev/null || return 2
  for launcher_id in verify doctor uninstall; do
    manifest_typed_value \
      "launchers.$launcher_id" dictionary >/dev/null || return 2
    for field in path_kind path sha256; do
      manifest_typed_value \
        "launchers.$launcher_id.$field" string >/dev/null || return 2
    done
    manifest_typed_value \
      "launchers.$launcher_id.owned" bool >/dev/null || return 2
  done

  owned="$(manifest_typed_value releases.current.owned bool)" || return 2
  case "$owned" in
    false)
      RELEASE_STATE=none
      return 0
      ;;
    true)
      ;;
    *)
      return 2
      ;;
  esac
  RELEASE_VERSION="$(manifest_typed_value \
    releases.current.version string)" || return 2
  path_kind="$(manifest_typed_value \
    releases.current.path_kind string)" || return 2
  RELEASE_PATH="$(manifest_typed_value \
    releases.current.path string)" || return 2
  archive_sha="$(manifest_typed_value \
    releases.current.archive_sha256 string)" || return 2
  tree_sha="$(manifest_typed_value \
    releases.current.tree_sha256 string)" || return 2
  case "$RELEASE_VERSION" in
    [A-Za-z0-9]*)
      case "$RELEASE_VERSION" in *[!A-Za-z0-9._-]*|*..*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  [ "$path_kind" = runtime_relative ] || return 2
  [ "$RELEASE_PATH" = "releases/$RELEASE_VERSION" ] || return 2
  validate_sha256_or_empty "$archive_sha" && [ -n "$archive_sha" ] || return 2
  validate_sha256_or_empty "$tree_sha" && [ -n "$tree_sha" ] || return 2
  validate_home_dir_path "$VIBE_MAC_RUNTIME_ROOT/releases/$RELEASE_VERSION" ||
    return 2
  validate_home_dir_path "$VIBE_MAC_RUNTIME_ROOT/bin" || return 2
  [ "$(manifest_typed_value current_link.path_kind string)" = runtime_relative ] ||
    return 2
  [ "$(manifest_typed_value current_link.path string)" = current ] || return 2
  current_target="$(manifest_typed_value current_link.target string)" || return 2
  [ "$current_target" = "$RELEASE_PATH" ] || return 2
  [ "$(manifest_typed_value current_link.owned bool)" = true ] || return 2

  present=0
  missing=0
  for target in \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" \
    "$VIBE_MAC_RUNTIME_ROOT/current" \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-verify" \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor" \
    "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-uninstall"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
      present=$((present + 1))
    else
      missing=$((missing + 1))
    fi
  done
  if [ "$present" -eq 0 ]; then
    RELEASE_STATE=removed
    return 0
  fi
  [ "$missing" -eq 0 ] || return 2

  [ -d "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" ] || return 2
  [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ] || return 2
  actual_current="$(/usr/bin/readlink "$VIBE_MAC_RUNTIME_ROOT/current")" ||
    return 2
  [ "$actual_current" = "$RELEASE_PATH" ] || return 2
  [ -f "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-sha256" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-sha256" ] ||
    return 2
  archive_marker_value="$(/bin/cat \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-sha256")" || return 2
  [ "$archive_marker_value" = "$archive_sha" ] || return 2
  [ -f "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-tree-sha256" ] &&
    [ ! -L "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-tree-sha256" ] ||
    return 2
  tree_marker_value="$(/bin/cat \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH/.bundle-tree-sha256")" ||
    return 2
  [ "$tree_marker_value" = "$tree_sha" ] || return 2
  actual_tree="$(release_tree_sha256 \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH")" || return 2
  [ "$actual_tree" = "$tree_sha" ] || return 2

  for launcher_id in verify doctor uninstall; do
    expected_path="bin/vibe-mac-$launcher_id"
    launcher_path_kind="$(manifest_typed_value \
      "launchers.$launcher_id.path_kind" string)" || return 2
    launcher_path="$(manifest_typed_value \
      "launchers.$launcher_id.path" string)" ||
      return 2
    expected_sha="$(manifest_typed_value \
      "launchers.$launcher_id.sha256" string)" ||
      return 2
    [ "$launcher_path_kind" = runtime_relative ] || return 2
    [ "$launcher_path" = "$expected_path" ] || return 2
    [ "$(manifest_typed_value \
      "launchers.$launcher_id.owned" bool)" = true ] ||
      return 2
    validate_sha256_or_empty "$expected_sha" &&
      [ -n "$expected_sha" ] || return 2
    target="$VIBE_MAC_RUNTIME_ROOT/$launcher_path"
    [ -f "$target" ] && [ ! -L "$target" ] || return 2
    actual_sha="$(sha256_file "$target")" || return 2
    [ "$actual_sha" = "$expected_sha" ] || return 2
  done
  RELEASE_STATE=ready
}

package_owned() {
  local kind name owned preexisting owner
  kind="$1"
  name="$2"
  owned="$(manifest_typed_value \
    "packages.$kind.$name.owned" bool 2>/dev/null || true)"
  preexisting="$(manifest_typed_value \
    "packages.$kind.$name.preexisting" bool 2>/dev/null || true)"
  owner="$(manifest_typed_value \
    "packages.$kind.$name.owner" string 2>/dev/null || true)"
  [ "$owned" = true ] &&
    [ "$preexisting" = false ] &&
    [ "$owner" = vibe-mac ]
}

file_entry_owned() {
  [ "$(manifest_typed_value \
    "files.$1.owned" bool 2>/dev/null || true)" = true ]
}

runtime_owned() {
  local name expected
  name="$1"
  expected="$2"
  [ "$(manifest_typed_value \
    "runtimes.$name.version" string 2>/dev/null || true)" = "$expected" ] &&
    [ "$(manifest_typed_value \
      "runtimes.$name.preexisting" bool 2>/dev/null || true)" = false ] &&
    [ "$(manifest_typed_value \
      "runtimes.$name.owned" bool 2>/dev/null || true)" = true ] &&
    uninstall_runtime_creation_proof_matches "$name" "$expected"
}

owned_runtime_count() {
  local count
  count=0
  runtime_owned node "$NODE_VERSION" && count=$((count + 1))
  runtime_owned python "$PYTHON_VERSION" && count=$((count + 1))
  printf '%s\n' "$count"
}

mise_runtime_inventory_remaining() {
  local root found
  root="$HOME/.local/share/mise/installs"
  validate_home_dir_path "$root" || return 2
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    return 1
  fi
  [ -d "$root" ] && [ ! -L "$root" ] &&
    [ -r "$root" ] && [ -x "$root" ] || return 2
  if [ -n "$(/usr/bin/find "$root" -mindepth 1 -type l -print -quit)" ]; then
    return 2
  fi
  found="$(/usr/bin/find \
    "$root" -mindepth 1 -maxdepth 1 ! -type d -print -quit)" || return 2
  [ -z "$found" ] || return 2
  found="$(/usr/bin/find \
    "$root" -mindepth 2 -print -quit)" || return 2
  [ -z "$found" ] && return 1
  return 0
}

prepare_mise_formula_preservation() {
  local status
  package_owned formulae mise || return 0
  if mise_runtime_inventory_remaining; then
    PRESERVE_MISE=1
    return 0
  else
    status="$?"
  fi
  case "$status" in
    1) return 0 ;;
    2)
      PRESERVE_MISE=1
      ui_warn "Runtime inventory mise небезопасен или недоступен; formula сохраняется."
      return 0
      ;;
    *) return 2 ;;
  esac
}

owned_package_count() {
  local name count
  count=0
  for name in $(formulae); do
    package_owned formulae "$name" && count=$((count + 1))
  done
  for name in $(casks); do
    package_owned casks "$name" && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

git_default_count() {
  local id count
  count=0
  for id in init-default-branch pull-rebase push-auto-upstream; do
    if manifest_value "git_defaults.$id" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

prepare_destructive_tools() {
  local package_count runtime_count count status
  package_count="$(owned_package_count)"
  runtime_count="$(owned_runtime_count)"
  count=$((package_count + runtime_count))
  if [ "$count" -gt 0 ]; then
    if BREW_BIN="$(destructive_homebrew_executable brew)"; then
      :
    else
      status="$?"
      [ "$status" -eq 1 ] || return 2
      BREW_BIN=
    fi
  fi

  if [ "$runtime_count" -gt 0 ] && [ -n "$BREW_BIN" ]; then
    if uninstall_brew_run list --formula mise >/dev/null 2>&1; then
      if MISE_BIN="$(destructive_homebrew_executable mise)"; then
        :
      else
        status="$?"
        [ "$status" -eq 1 ] || return 2
        MISE_BIN=
      fi
    else
      MISE_BIN=
    fi
  fi

  count="$(git_default_count)"
  if [ "$count" -gt 0 ]; then
    if GIT_BIN="$(destructive_homebrew_executable git)"; then
      :
    else
      status="$?"
      [ "$status" -eq 1 ] || return 2
      GIT_BIN=
    fi
  fi
}

show_plan() {
  local name found
  found=0
  printf '%s\n' "План удаления (пока без изменений):"
  if runtime_owned node "$NODE_VERSION"; then
    printf '  - runtime: node@%s\n' "$NODE_VERSION"
    found=1
  fi
  if runtime_owned python "$PYTHON_VERSION"; then
    printf '  - runtime: python@%s\n' "$PYTHON_VERSION"
    found=1
  fi
  for name in $(formulae); do
    if package_owned formulae "$name"; then
      printf '  - Homebrew formula: %s\n' "$name"
      found=1
    fi
  done
  for name in $(casks); do
    if package_owned casks "$name"; then
      printf '  - Homebrew cask: %s (без zap)\n' "$name"
      found=1
    fi
  done
  for name in zprofile zshrc ghostty aliases starship mise-global; do
    if file_entry_owned "$name"; then
      printf '  - managed file entry: %s\n' "$name"
      found=1
    fi
  done
  for name in dock_autohide finder_extensions; do
    if manifest_value "defaults.$name" >/dev/null 2>&1; then
      printf '  - восстановить macOS default: %s\n' "$name"
      found=1
    fi
  done
  for name in init-default-branch pull-rebase push-auto-upstream; do
    if manifest_value "git_defaults.$name" >/dev/null 2>&1; then
      printf '  - удалить созданный Git default: %s\n' "$name"
      found=1
    fi
  done
  if [ "$(manifest_typed_value \
    components.oh_my_zsh.owned bool 2>/dev/null || true)" = true ]; then
    printf '%s\n' "  - owned tree: .oh-my-zsh"
    found=1
  fi
  case "$RELEASE_STATE" in
    ready)
      printf '  - verified release bundle: %s\n' "$RELEASE_PATH"
      found=1
      ;;
    removed)
      printf '  - release bundle уже удалён: %s\n' "$RELEASE_PATH"
      ;;
  esac
  if [ "$found" = 0 ]; then
    printf '%s\n' "  - owned-компонентов в manifest нет"
  fi
  printf '%s\n' \
    "Сохраняются: Homebrew, Xcode CLT, workspace, аккаунты, credentials," \
    "логи, state и $VIBE_MAC_BACKUP_ROOT."
}

preserve_runtime_conflict() {
  local name version reason
  name="$1"
  version="$2"
  reason="$3"
  ui_warn "Owned runtime $name@$version: $reason; конфликт, оставляю."
  CONFLICTS=$((CONFLICTS + 1))
  PRESERVE_MISE=1
}

remove_owned_runtime() {
  local name version item expected_path reported_path command expected_output
  local actual_output
  name="$1"
  version="$2"
  runtime_owned "$name" "$version" || return 0
  item="$name@$version"
  expected_path="$HOME/.local/share/mise/installs/$name/$version"
  validate_home_dir_path "$expected_path" || return 2

  if [ ! -e "$expected_path" ] && [ ! -L "$expected_path" ]; then
    if [ -z "$MISE_BIN" ]; then
      return 0
    fi
    if reported_path="$(uninstall_mise_run where "$item" 2>/dev/null)"; then
      preserve_runtime_conflict \
        "$name" "$version" "mise сообщает неожиданный path $reported_path"
    fi
    return 0
  fi

  if [ -z "$MISE_BIN" ]; then
    preserve_runtime_conflict "$name" "$version" "trusted Homebrew mise недоступен"
    return 0
  fi

  if ! reported_path="$(uninstall_mise_run where "$item" 2>/dev/null)"; then
    preserve_runtime_conflict "$name" "$version" "mise where не подтвердил установку"
    return 0
  fi
  if [ "$reported_path" != "$expected_path" ]; then
    preserve_runtime_conflict \
      "$name" "$version" "mise where вернул неожиданный path"
    return 0
  fi
  [ -d "$expected_path" ] && [ ! -L "$expected_path" ] || return 2

  case "$name" in
    node)
      command=node
      expected_output="v$version"
      ;;
    python)
      command=python
      expected_output="Python $version"
      ;;
    *)
      return 2
      ;;
  esac
  if ! actual_output="$(uninstall_mise_run \
    exec "$item" -- "$command" --version 2>/dev/null)"; then
    preserve_runtime_conflict "$name" "$version" "version check не выполнен"
    return 0
  fi
  if [ "$actual_output" != "$expected_output" ]; then
    preserve_runtime_conflict "$name" "$version" "version drift"
    return 0
  fi

  if ! uninstall_mise_run uninstall "$item"; then
    preserve_runtime_conflict "$name" "$version" "mise uninstall завершился ошибкой"
    return 0
  fi
  if uninstall_mise_run where "$item" >/dev/null 2>&1 ||
    [ -e "$expected_path" ] || [ -L "$expected_path" ]; then
    preserve_runtime_conflict "$name" "$version" "post-check не подтвердил удаление"
  fi
}

remove_owned_runtimes() {
  remove_owned_runtime node "$NODE_VERSION"
  remove_owned_runtime python "$PYTHON_VERSION"
}

uninstall_formula() {
  local name dependents expected current line
  name="$1"
  if ! uninstall_brew_run list --formula "$name" >/dev/null 2>&1; then
    return 0
  fi
  expected="$(manifest_typed_value \
    "packages.formulae.$name.version_after" string)" ||
    return 2
  line="$(uninstall_brew_run \
    list --formula --versions "$name" 2>/dev/null)" || {
    ui_warn "Не удалось проверить version formula $name; оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  }
  current="${line#"$name" }"
  if [ -z "$current" ] || [ "$current" != "$expected" ]; then
    ui_warn "Formula $name имеет version drift; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  dependents="$(uninstall_brew_run \
    uses --installed "$name" 2>/dev/null)" || {
    ui_warn "Не удалось проверить dependents formula $name; оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  }
  if [ -n "$dependents" ]; then
    ui_warn "Formula $name нужна другим пакетам; оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  uninstall_brew_run uninstall "$name"
}

uninstall_cask() {
  local name expected current line
  name="$1"
  if uninstall_brew_run list --cask "$name" >/dev/null 2>&1; then
    expected="$(manifest_typed_value \
      "packages.casks.$name.version_after" string)" ||
      return 2
    line="$(uninstall_brew_run \
      list --cask --versions "$name" 2>/dev/null)" || {
      ui_warn "Не удалось проверить version cask $name; оставляю."
      CONFLICTS=$((CONFLICTS + 1))
      return 0
    }
    current="${line#"$name" }"
    if [ -z "$current" ] || [ "$current" != "$expected" ]; then
      ui_warn "Cask $name имеет version drift; конфликт, оставляю."
      CONFLICTS=$((CONFLICTS + 1))
      return 0
    fi
    uninstall_brew_run uninstall --cask "$name"
  fi
}

block_content_sha() {
  local target block_id begin end
  target="$1"
  block_id="$2"
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"
  /usr/bin/awk -v begin="$begin" -v end="$end" '
    $0 == begin {
      if (inside || seen) exit 40
      inside = 1
      seen = 1
      next
    }
    $0 == end {
      if (!inside) exit 41
      inside = 0
      closed = 1
      next
    }
    inside { print }
    END {
      if (!seen || !closed || inside) exit 42
    }
  ' "$target" | sha256_stream
}

sha256_stream() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  elif [ -x /usr/bin/sha256sum ]; then
    /usr/bin/sha256sum | /usr/bin/awk '{print $1}'
  else
    return 2
  fi
}

remove_managed_block() {
  local id target block_id expected actual begin end parent temp
  id="$1"
  target="$2"
  block_id="$3"
  expected="$(manifest_typed_value \
    "files.$id.applied_sha" string)" || return 2
  if [ ! -e "$target" ]; then
    return 0
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    ui_warn "Файл $target стал небезопасным; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  actual="$(block_content_sha "$target" "$block_id" 2>/dev/null)" || {
    ui_warn "Managed block $id изменён или malformed; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  }
  if [ "$actual" != "$expected" ]; then
    ui_warn "Managed block $id изменён; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"
  parent="${target%/*}"
  temp="$(/usr/bin/mktemp "$parent/.vibe-mac-uninstall.XXXXXX")"
  if ! /usr/bin/awk -v begin="$begin" -v end="$end" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    !inside { print }
  ' "$target" >"$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod "$(file_mode "$target")" "$temp"
  /bin/mv -f "$temp" "$target"
}

remove_owned_file() {
  local id target expected actual
  id="$1"
  target="$2"
  expected="$(manifest_typed_value \
    "files.$id.applied_sha" string)" || return 2
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    ui_warn "Owned file $id стал небезопасным; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  actual="$(sha256_file "$target")" || return 2
  if [ "$actual" != "$expected" ]; then
    ui_warn "Owned file $id изменён; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  /bin/unlink "$target"
}

remove_owned_omz() {
  local target expected actual
  if [ "$(manifest_typed_value components.oh_my_zsh.owned bool)" != true ]; then
    return 0
  fi
  target="$HOME/.oh-my-zsh"
  expected="$(manifest_typed_value components.oh_my_zsh.tree_sha256 string)"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ -L "$target" ] || [ ! -d "$target" ]; then
    ui_warn "Owned Oh My Zsh path стал небезопасным; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  actual="$(tree_sha256 "$target" 2>/dev/null)" || {
    ui_warn "Oh My Zsh tree нельзя безопасно проверить; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  }
  if [ "$actual" != "$expected" ]; then
    ui_warn "Oh My Zsh изменён; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  /usr/bin/find "$target" -depth -delete
}

prepare_uninstall_self_copy() {
  local parent relative source destination source_sha copy_sha
  parent="$(uninstall_temp_parent)" || return 2
  UNINSTALL_TEMP="$(/usr/bin/mktemp -d \
    "$parent/vibe-mac-uninstall.XXXXXX")"
  /bin/chmod 0700 "$UNINSTALL_TEMP"
  /bin/mkdir "$UNINSTALL_TEMP/config" "$UNINSTALL_TEMP/lib"
  /bin/chmod 0700 "$UNINSTALL_TEMP/config" "$UNINSTALL_TEMP/lib"
  : >"$UNINSTALL_TEMP/.runtime-sha256"
  /bin/chmod 0600 "$UNINSTALL_TEMP/.runtime-sha256"

  for relative in \
    uninstall.sh \
    config/versions.env \
    lib/guard.sh \
    lib/ui.sh \
    lib/util.sh; do
    source="$VIBE_MAC_ROOT/$relative"
    destination="$UNINSTALL_TEMP/$relative"
    [ -f "$source" ] && [ ! -L "$source" ] || return 2
    /bin/cp "$source" "$destination"
    case "$relative" in
      uninstall.sh) /bin/chmod 0700 "$destination" ;;
      *) /bin/chmod 0600 "$destination" ;;
    esac
    source_sha="$(sha256_file "$source")" || return 2
    copy_sha="$(sha256_file "$destination")" || return 2
    [ "$source_sha" = "$copy_sha" ] || return 2
    printf '%s  %s\n' "$copy_sha" "$relative" \
      >>"$UNINSTALL_TEMP/.runtime-sha256"
  done

  UNINSTALL_RUNTIME_MANIFEST_SHA256="$(sha256_file \
    "$UNINSTALL_TEMP/.runtime-sha256")" || return 2
  validate_uninstall_runtime \
    "$UNINSTALL_TEMP" \
    "$UNINSTALL_RUNTIME_MANIFEST_SHA256"
}

run_uninstall_self_copy() {
  local run_user clean_path clean_tmp
  run_user="$(/usr/bin/id -un)" || return 2
  clean_path=/usr/bin:/bin:/usr/sbin:/sbin
  clean_tmp=/tmp

  if is_test_mode; then
    if [ "${VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR:-0}" != 1 ]; then
      clean_tmp="${TMPDIR:-/tmp}"
    fi
    /usr/bin/env -i \
      HOME="$HOME" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      PATH="$clean_path" \
      TMPDIR="$clean_tmp" \
      LANG=C \
      LC_ALL=C \
      VIBE_MAC_UNINSTALL_RUNTIME_MANIFEST_SHA256="$UNINSTALL_RUNTIME_MANIFEST_SHA256" \
      VIBE_MAC_TEST_MODE=1 \
      VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR="${VIBE_MAC_TEST_FORCE_PRODUCTION_TMPDIR:-0}" \
      TEST_ROOT="${TEST_ROOT:-}" \
      VIBE_MAC_PLUTIL_BIN="${VIBE_MAC_PLUTIL_BIN:-}" \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" \
      VIBE_MAC_TEST_UNINSTALL_FORMULAE="${VIBE_MAC_TEST_UNINSTALL_FORMULAE:-}" \
      VIBE_MAC_TEST_UNINSTALL_CASKS="${VIBE_MAC_TEST_UNINSTALL_CASKS:-}" \
      VIBE_MAC_DEFAULTS_BIN="${VIBE_MAC_DEFAULTS_BIN:-}" \
      VIBE_MAC_DEFAULTS_STATE="${VIBE_MAC_DEFAULTS_STATE:-}" \
      VIBE_MAC_KILLALL_BIN="${VIBE_MAC_KILLALL_BIN:-}" \
      VIBE_MAC_BREW_STATE="${VIBE_MAC_BREW_STATE:-}" \
      VIBE_MAC_GIT_STATE="${VIBE_MAC_GIT_STATE:-}" \
      VIBE_MAC_MISE_STATE="${VIBE_MAC_MISE_STATE:-}" \
      VIBE_MAC_OWNED_VERSION="${VIBE_MAC_OWNED_VERSION:-}" \
      VIBE_MAC_TEST_BREW_USES_FAIL="${VIBE_MAC_TEST_BREW_USES_FAIL:-0}" \
      VIBE_MAC_TEST_BREW_DEPENDENT="${VIBE_MAC_TEST_BREW_DEPENDENT:-0}" \
      VIBE_MAC_TEST_MISE_WHERE_OVERRIDE="${VIBE_MAC_TEST_MISE_WHERE_OVERRIDE:-}" \
      VIBE_MAC_TEST_MISE_VERSION_OVERRIDE="${VIBE_MAC_TEST_MISE_VERSION_OVERRIDE:-}" \
      /bin/bash "$UNINSTALL_TEMP/uninstall.sh" --internal-apply
    return
  fi

  /usr/bin/env -i \
    HOME="$HOME" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    PATH="$clean_path" \
    TMPDIR=/tmp \
    LANG=C \
    LC_ALL=C \
    VIBE_MAC_UNINSTALL_RUNTIME_MANIFEST_SHA256="$UNINSTALL_RUNTIME_MANIFEST_SHA256" \
    /bin/bash "$UNINSTALL_TEMP/uninstall.sh" --internal-apply
}

remove_release_bundle() {
  local launcher
  [ "$RELEASE_STATE" = ready ] || return 0
  validate_release_entry || return 2
  [ "$RELEASE_STATE" = ready ] || return 2
  for launcher in verify doctor uninstall; do
    /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher"
  done
  /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  /usr/bin/find \
    "$VIBE_MAC_RUNTIME_ROOT/$RELEASE_PATH" -depth -delete
  RELEASE_STATE=removed
}

restore_default() {
  local id domain key original_exists original_value applied_value
  local tool restarter current
  id="$1"
  if ! manifest_value "defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  domain="$(manifest_typed_value "defaults.$id.domain" string)" || return 2
  key="$(manifest_typed_value "defaults.$id.key" string)" || return 2
  original_exists="$(manifest_typed_value \
    "defaults.$id.original_exists" bool)" || return 2
  original_value="$(manifest_typed_value \
    "defaults.$id.original_value" bool)" || return 2
  applied_value="$(manifest_typed_value \
    "defaults.$id.applied_value" bool)" || return 2
  case "$id:$domain:$key" in
    dock_autohide:com.apple.dock:autohide) ;;
    finder_extensions:NSGlobalDomain:AppleShowAllExtensions) ;;
    *) return 2 ;;
  esac
  case "$original_exists:$original_value:$applied_value" in
    true:true:true|true:false:true|false:false:true) ;;
    *) return 2 ;;
  esac
  tool="$(defaults_tool)"
  restarter="$(killall_tool)"
  current="$("$tool" read "$domain" "$key" 2>/dev/null || true)"
  case "$current" in 1|true|TRUE|YES|yes) ;; *)
    ui_warn "Default $id уже изменён после установки; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  esac
  if [ "$original_exists" = true ]; then
    "$tool" write "$domain" "$key" -bool "$original_value"
  else
    "$tool" delete "$domain" "$key"
  fi
  case "$id" in
    dock_autohide) "$restarter" Dock >/dev/null 2>&1 || true ;;
    finder_extensions) "$restarter" Finder >/dev/null 2>&1 || true ;;
  esac
}

remove_git_default() {
  local id key expected current
  id="$1"
  if ! manifest_value "git_defaults.$id" >/dev/null 2>&1; then
    return 0
  fi
  key="$(manifest_typed_value "git_defaults.$id.key" string)" || return 2
  expected="$(manifest_typed_value \
    "git_defaults.$id.applied_value" string)" || return 2
  current="$(uninstall_git_run \
    config --global --get "$key" 2>/dev/null || true)"
  if [ -z "$current" ]; then
    return 0
  fi
  if [ "$current" != "$expected" ]; then
    ui_warn "Git default $key изменён пользователем; конфликт, оставляю."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi
  uninstall_git_run config --global --unset "$key"
}

apply_files() {
  if file_entry_owned zprofile; then
    remove_managed_block zprofile "$HOME/.zprofile" zprofile
  fi
  if file_entry_owned zshrc; then
    remove_managed_block zshrc "$HOME/.zshrc" zshrc
  fi
  if file_entry_owned ghostty; then
    remove_managed_block ghostty \
      "$HOME/Library/Application Support/com.mitchellh.ghostty/config" ghostty
  fi
  if file_entry_owned aliases; then
    remove_owned_file aliases "$HOME/.config/vibe-mac/aliases.zsh"
  fi
  if file_entry_owned starship; then
    remove_owned_file starship "$HOME/.config/starship.toml"
  fi
  if file_entry_owned mise-global; then
    remove_owned_file mise-global "$HOME/.config/mise/config.toml"
  fi
}

apply_uninstall() {
  local name preserved
  if [ -n "$GIT_BIN" ]; then
    remove_git_default init-default-branch
    remove_git_default pull-rebase
    remove_git_default push-auto-upstream
  else
    preserved="$(git_default_count)"
    if [ "$preserved" -gt 0 ]; then
      ui_warn "Homebrew Git недоступен; owned Git defaults оставлены."
      CONFLICTS=$((CONFLICTS + preserved))
    fi
  fi

  remove_owned_runtimes
  prepare_mise_formula_preservation

  if [ -n "$BREW_BIN" ]; then
    for name in $(formulae); do
      if package_owned formulae "$name"; then
        if [ "$name" = mise ] && [ "$PRESERVE_MISE" -eq 1 ]; then
          ui_warn "Formula mise нужна сохранённому runtime; оставляю."
          CONFLICTS=$((CONFLICTS + 1))
          continue
        fi
        uninstall_formula "$name"
      fi
    done
    for name in $(casks); do
      if package_owned casks "$name"; then
        uninstall_cask "$name"
      fi
    done
  else
    preserved="$(owned_package_count)"
    if [ "$preserved" -gt 0 ]; then
      ui_warn "Homebrew недоступен; owned packages оставлены."
      CONFLICTS=$((CONFLICTS + preserved))
    fi
  fi
  apply_files
  remove_owned_omz
  restore_default dock_autohide
  restore_default finder_extensions
  remove_release_bundle
}

case "${1:-}" in
  "")
    ;;
  --dry-run)
    ;;
  --apply)
    APPLY=1
    ;;
  --internal-apply)
    [ "$INTERNAL_APPLY" -eq 1 ] || exit 2
    APPLY=1
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
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

validate_manifest
validate_packages
validate_file_entries
validate_runtimes
validate_git_defaults
validate_defaults
validate_omz_entry
if ! validate_release_entry; then
  ui_fail "Manifest/runtime release ownership не прошёл integrity-проверку."
  exit 2
fi

if [ "$INTERNAL_APPLY" -eq 1 ]; then
  if is_test_mode; then
    printf 'uninstall-runtime:%s\n' "$SCRIPT_DIR" >>"$VIBE_MAC_EVENT_LOG"
  fi
  if ! prepare_destructive_tools; then
    ui_fail "Destructive tool provenance не прошёл integrity-проверку."
    exit 2
  fi
  apply_uninstall
  printf '%s\n' \
    "Удаление owned-компонентов завершено." \
    "Workspace, аккаунты, credentials, state, logs и backups сохранены."
  if [ "$CONFLICTS" -gt 0 ]; then
    ui_warn "Найдено конфликтов: $CONFLICTS; изменённые файлы сохранены."
    exit 1
  fi
  exit 0
fi

show_plan

if [ "$APPLY" = 0 ]; then
  exit 0
fi
if ! ui_confirm_typed \
  "Удаление затронет только owned-цели из плана." \
  UNINSTALL; then
  ui_warn "Удаление отменено; точное слово UNINSTALL не введено."
  exit 1
fi

trap cleanup_uninstall_temp EXIT
trap 'exit 130' INT TERM HUP
prepare_uninstall_self_copy || {
  ui_fail "Self-copy uninstall не прошёл SHA-проверку."
  exit 2
}
if run_uninstall_self_copy; then
  child_status=0
else
  child_status="$?"
fi
exit "$child_status"
