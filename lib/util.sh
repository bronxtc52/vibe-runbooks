#!/usr/bin/env bash
set -euo pipefail

: "${HOME:?HOME не задан}"

# `git archive` replaces this literal with the exact release commit. Test
# seams are available only from an unarchived source checkout; a packaged
# release always forces production mode regardless of the caller environment.
# shellcheck disable=SC2016
VIBE_MAC_BUILD_COMMIT='$Format:%H$'
# shellcheck disable=SC2016
case "$VIBE_MAC_BUILD_COMMIT" in
  *'$Format:'*)
    VIBE_MAC_BUILD_KIND=source
    ;;
  *)
    if [ "${#VIBE_MAC_BUILD_COMMIT}" -ne 40 ] ||
      ! printf '%s\n' "$VIBE_MAC_BUILD_COMMIT" |
      LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{40}$'; then
      printf '%s\n' 'Ошибка: неизвестный build marker vibe-mac.' >&2
      return 2
    fi
    VIBE_MAC_BUILD_KIND=release
    VIBE_MAC_TEST_MODE=0
    export VIBE_MAC_TEST_MODE
    ;;
esac
readonly VIBE_MAC_BUILD_COMMIT VIBE_MAC_BUILD_KIND
export VIBE_MAC_BUILD_COMMIT VIBE_MAC_BUILD_KIND

if [ "${VIBE_MAC_TEST_MODE:-0}" = "1" ]; then
  VIBE_MAC_RUNTIME_ROOT="${VIBE_MAC_RUNTIME_ROOT:-$HOME/.vibe-mac}"
  VIBE_MAC_BACKUP_ROOT="${VIBE_MAC_BACKUP_ROOT:-$HOME/.vibe-mac-backup}"
  VIBE_MAC_STATE_DIR="${VIBE_MAC_STATE_DIR:-$VIBE_MAC_RUNTIME_ROOT/state}"
  VIBE_MAC_LOG_DIR="${VIBE_MAC_LOG_DIR:-$VIBE_MAC_RUNTIME_ROOT/logs}"
  VIBE_MAC_STATE_FILE="${VIBE_MAC_STATE_FILE:-$VIBE_MAC_STATE_DIR/progress.json}"
  VIBE_MAC_MANIFEST_FILE="${VIBE_MAC_MANIFEST_FILE:-$VIBE_MAC_STATE_DIR/manifest.json}"
  VIBE_MAC_LOCK_DIR="${VIBE_MAC_LOCK_DIR:-$VIBE_MAC_STATE_DIR/install.lock.d}"
  VIBE_MAC_LOG_FILE="${VIBE_MAC_LOG_FILE:-}"
else
  # Production writes are deliberately pinned to a small HOME-relative allowlist.
  # Environment overrides are test seams, not a supported way to redirect writes.
  VIBE_MAC_RUNTIME_ROOT="$HOME/.vibe-mac"
  VIBE_MAC_BACKUP_ROOT="$HOME/.vibe-mac-backup"
  VIBE_MAC_STATE_DIR="$VIBE_MAC_RUNTIME_ROOT/state"
  VIBE_MAC_LOG_DIR="$VIBE_MAC_RUNTIME_ROOT/logs"
  VIBE_MAC_STATE_FILE="$VIBE_MAC_STATE_DIR/progress.json"
  VIBE_MAC_MANIFEST_FILE="$VIBE_MAC_STATE_DIR/manifest.json"
  VIBE_MAC_LOCK_DIR="$VIBE_MAC_STATE_DIR/install.lock.d"
  VIBE_MAC_LOG_FILE=
fi

export VIBE_MAC_RUNTIME_ROOT
export VIBE_MAC_BACKUP_ROOT
export VIBE_MAC_STATE_DIR
export VIBE_MAC_LOG_DIR
export VIBE_MAC_STATE_FILE
export VIBE_MAC_MANIFEST_FILE
export VIBE_MAC_LOCK_DIR
export VIBE_MAC_LOG_FILE

is_test_mode() {
  [ "${VIBE_MAC_TEST_MODE:-0}" = "1" ]
}

validate_bool() {
  local name value
  name="$1"
  value="$2"
  case "$value" in
    0|1)
      return 0
      ;;
    *)
      printf 'Ошибка: %s принимает только 0 или 1.\n' "$name" >&2
      return 2
      ;;
  esac
}

have() {
  command -v "$1" >/dev/null 2>&1
}

version_at_least() {
  local actual minimum
  actual="$1"
  minimum="$2"
  /usr/bin/awk -v actual="$actual" -v minimum="$minimum" '
    BEGIN {
      actual_count = split(actual, a, ".")
      minimum_count = split(minimum, m, ".")
      count = actual_count > minimum_count ? actual_count : minimum_count
      for (i = 1; i <= count; i++) {
        av = a[i] + 0
        mv = m[i] + 0
        if (av > mv) exit 0
        if (av < mv) exit 1
      }
      exit 0
    }
  '
}

utc_now() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

run_id_now() {
  printf '%s-%s\n' "$(/bin/date -u '+%Y%m%dT%H%M%SZ')" "$$"
}

sha256_file() {
  local file
  file="$1"
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif have sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  else
    printf 'Ошибка: не найден SHA-256 инструмент.\n' >&2
    return 2
  fi
}

sha256_stdin() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  elif have sha256sum; then
    sha256sum | awk '{print $1}'
  else
    printf 'Ошибка: не найден SHA-256 инструмент.\n' >&2
    return 2
  fi
}

sha256_text() {
  printf '%s\n' "$1" | sha256_stdin
}

validate_sha256_or_empty() {
  case "$1" in
    "") return 0 ;;
    *[!A-Fa-f0-9]*) return 2 ;;
  esac
  [ "${#1}" -eq 64 ]
}

homebrew_executable_in_prefix() {
  local prefix name bin candidate resolved prefix_resolved bin_resolved
  prefix="$1"
  name="$2"
  case "$prefix" in
    /*)
      case "$prefix" in *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  case "$name" in
    ""|*/*|*[!A-Za-z0-9._+-]*) return 2 ;;
  esac
  bin="$prefix/bin"
  candidate="$bin/$name"
  [ -d "$prefix" ] && [ ! -L "$prefix" ] || return 1
  [ -d "$bin" ] && [ ! -L "$bin" ] || return 1
  [ -e "$candidate" ] || [ -L "$candidate" ] || return 1
  [ -x /bin/realpath ] || return 2
  prefix_resolved="$(/bin/realpath "$prefix" 2>/dev/null)" || return 1
  bin_resolved="$(/bin/realpath "$bin" 2>/dev/null)" || return 1
  [ "$bin_resolved" = "$prefix_resolved/bin" ] || return 2
  resolved="$(/bin/realpath "$candidate" 2>/dev/null)" || return 1
  case "$resolved" in
    "$prefix_resolved"/*) ;;
    *) return 2 ;;
  esac
  [ -f "$resolved" ] && [ ! -L "$resolved" ] && [ -x "$resolved" ] ||
    return 2
  printf '%s\n' "$resolved"
}

validate_shell_homebrew_prefix_literal() {
  case "$1" in
    /*)
      case "$1" in *$'\n'*|*$'\r'*|*$'\t'*|*"'"*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
}

shell_homebrew_resolver_content() {
  # This resolver is embedded verbatim in managed zsh files. It accepts only
  # the fixed paths generated below, resolves them with the system realpath,
  # and never executes or sources a target that escapes the trusted prefix.
  # shellcheck disable=SC2016
  printf '%s\n' '_vibe_mac_homebrew_resolve() {
  _vibe_mac_relative="${1:-}"
  _vibe_mac_access="${2:-}"
  case "$_vibe_mac_relative:$_vibe_mac_access" in
    bin/brew:x|bin/mise:x|bin/zoxide:x|bin/starship:x)
      ;;
    opt/fzf/shell/completion.zsh:r|opt/fzf/shell/key-bindings.zsh:r)
      ;;
    *)
      return 1
      ;;
  esac
  [ -x /bin/realpath ] || return 1
  [ -d "$_vibe_mac_homebrew_prefix" ] &&
    [ ! -L "$_vibe_mac_homebrew_prefix" ] || return 1
  [ -d "$_vibe_mac_homebrew_prefix/bin" ] &&
    [ ! -L "$_vibe_mac_homebrew_prefix/bin" ] || return 1
  _vibe_mac_prefix_physical="$(
    /bin/realpath "$_vibe_mac_homebrew_prefix" 2>/dev/null
  )" || return 1
  _vibe_mac_bin_physical="$(
    /bin/realpath "$_vibe_mac_homebrew_prefix/bin" 2>/dev/null
  )" || return 1
  [ "$_vibe_mac_bin_physical" = "$_vibe_mac_prefix_physical/bin" ] ||
    return 1
  _vibe_mac_candidate="$_vibe_mac_homebrew_prefix/$_vibe_mac_relative"
  [ -e "$_vibe_mac_candidate" ] || [ -L "$_vibe_mac_candidate" ] ||
    return 1
  _vibe_mac_resolved="$(/bin/realpath "$_vibe_mac_candidate" 2>/dev/null)" ||
    return 1
  case "$_vibe_mac_resolved" in
    "$_vibe_mac_prefix_physical"/*) ;;
    *) return 1 ;;
  esac
  [ -f "$_vibe_mac_resolved" ] && [ ! -L "$_vibe_mac_resolved" ] ||
    return 1
  case "$_vibe_mac_access" in
    x) [ -x "$_vibe_mac_resolved" ] || return 1 ;;
    r) [ -r "$_vibe_mac_resolved" ] || return 1 ;;
    *) return 1 ;;
  esac
  printf "%s\\n" "$_vibe_mac_resolved"
}'
}

shell_zprofile_managed_content_for_prefix() {
  local prefix resolver
  prefix="$1"
  validate_shell_homebrew_prefix_literal "$prefix" || return 2
  resolver="$(shell_homebrew_resolver_content)" || return 2
  printf "_vibe_mac_homebrew_prefix='%s'\n" "$prefix"
  printf '%s\n' "$resolver"
  # shellcheck disable=SC2016
  printf '%s\n' 'if _vibe_mac_brew="$(
  _vibe_mac_homebrew_resolve bin/brew x
)"; then
  eval "$("$_vibe_mac_brew" shellenv)"
fi
export PATH="$HOME/.vibe-mac/bin:$HOME/.local/bin:$PATH"
if _vibe_mac_mise="$(
  _vibe_mac_homebrew_resolve bin/mise x
)"; then
  eval "$("$_vibe_mac_mise" activate zsh --shims)"
fi
unset -f _vibe_mac_homebrew_resolve
unset _vibe_mac_homebrew_prefix _vibe_mac_brew _vibe_mac_mise'
}

shell_zshrc_activation_content_for_prefix() {
  local prefix resolver
  prefix="$1"
  validate_shell_homebrew_prefix_literal "$prefix" || return 2
  resolver="$(shell_homebrew_resolver_content)" || return 2
  # shellcheck disable=SC2016
  printf '%s\n' 'if [ -f "$HOME/.config/vibe-mac/aliases.zsh" ] &&
  [ ! -L "$HOME/.config/vibe-mac/aliases.zsh" ]; then
  source "$HOME/.config/vibe-mac/aliases.zsh"
fi'
  printf "_vibe_mac_homebrew_prefix='%s'\n" "$prefix"
  printf '%s\n' "$resolver"
  # shellcheck disable=SC2016
  printf '%s\n' 'if _vibe_mac_mise="$(
  _vibe_mac_homebrew_resolve bin/mise x
)"; then
  eval "$("$_vibe_mac_mise" activate zsh)"
fi
if _vibe_mac_fzf_completion="$(
  _vibe_mac_homebrew_resolve opt/fzf/shell/completion.zsh r
)"; then
  source "$_vibe_mac_fzf_completion"
fi
if _vibe_mac_fzf_bindings="$(
  _vibe_mac_homebrew_resolve opt/fzf/shell/key-bindings.zsh r
)"; then
  source "$_vibe_mac_fzf_bindings"
fi
if _vibe_mac_zoxide="$(
  _vibe_mac_homebrew_resolve bin/zoxide x
)"; then
  eval "$("$_vibe_mac_zoxide" init zsh)"
fi
if _vibe_mac_starship="$(
  _vibe_mac_homebrew_resolve bin/starship x
)"; then
  eval "$("$_vibe_mac_starship" init zsh)"
fi
unset -f _vibe_mac_homebrew_resolve
unset _vibe_mac_homebrew_prefix _vibe_mac_mise _vibe_mac_fzf_completion
unset _vibe_mac_fzf_bindings _vibe_mac_zoxide _vibe_mac_starship'
}

shell_zshrc_managed_content_for_prefix() {
  local activation prefix
  prefix="$1"
  activation="$(shell_zshrc_activation_content_for_prefix "$prefix")" ||
    return 2
  # shellcheck disable=SC2016
  printf '%s\n' 'export ZSH="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$HOME/.config/oh-my-zsh/custom"
ZSH_CACHE_DIR="$HOME/.cache/oh-my-zsh"
zstyle :omz:update mode disabled
ZSH_THEME=""
plugins=(git)
if [ -r "$ZSH/oh-my-zsh.sh" ]; then
  source "$ZSH/oh-my-zsh.sh"
fi'
  printf '%s\n' "$activation"
}

homebrew_env_files_safe() {
  local prefix file
  prefix="$1"
  case "$prefix" in /*) ;; *) return 2 ;; esac
  for file in /etc/homebrew/brew.env "$prefix/etc/homebrew/brew.env"; do
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      continue
    fi
    [ -f "$file" ] && [ ! -L "$file" ] || return 2
    [ ! -s "$file" ] || return 2
  done
}

macos_app_bundle_ready() {
  local app contents info macos executable identifier executable_path
  app="$1"
  contents="$app/Contents"
  info="$contents/Info.plist"
  macos="$contents/MacOS"
  [ -d "$app" ] && [ ! -L "$app" ] || return 1
  [ -d "$contents" ] && [ ! -L "$contents" ] || return 1
  [ -f "$info" ] && [ ! -L "$info" ] || return 1
  [ -d "$macos" ] && [ ! -L "$macos" ] || return 1
  plutil_run -lint "$info" >/dev/null 2>&1 || return 1
  executable="$(plutil_run -extract CFBundleExecutable raw -expect string -- \
    "$info" 2>/dev/null)" || return 1
  identifier="$(plutil_run -extract CFBundleIdentifier raw -expect string -- \
    "$info" 2>/dev/null)" || return 1
  case "$executable" in
    ""|*/*|*\\*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  case "$identifier" in
    ""|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;;
  esac
  executable_path="$macos/$executable"
  [ -f "$executable_path" ] && [ ! -L "$executable_path" ] &&
    [ -x "$executable_path" ]
}

font_file_sfnt_ready() {
  local file size magic
  file="$1"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  if size="$(/usr/bin/stat -f '%z' "$file" 2>/dev/null)"; then
    :
  else
    size="$(/usr/bin/stat -c '%s' "$file" 2>/dev/null)" || return 1
  fi
  case "$size" in ""|*[!0-9]*) return 1 ;; esac
  [ "$size" -ge 1024 ] || return 1
  magic="$(/usr/bin/od -An -tx1 -N4 "$file" 2>/dev/null |
    /usr/bin/tr -d ' \n')" || return 1
  case "$magic" in
    00010000|4f54544f|74746366) return 0 ;;
    *) return 1 ;;
  esac
}

font_dir_has_jetbrains_mono_nerd_font() {
  local font_dir file
  font_dir="$1"
  [ -d "$font_dir" ] && [ ! -L "$font_dir" ] || return 1
  while IFS= read -r -d '' file; do
    if font_file_sfnt_ready "$file"; then
      return 0
    fi
  done < <(
    /usr/bin/find "$font_dir" -maxdepth 1 -type f \
      \( -iname 'JetBrainsMono*NerdFont*.ttf' -o \
         -iname 'JetBrainsMono*NerdFont*.otf' \) -print0
  )
  return 1
}

validate_home_relative() {
  local path
  path="$1"
  case "$path" in
    ""|/*|*\\*|*\"*|*$'\n'*|*$'\r'*|*$'\t'*)
      printf 'Ошибка: небезопасный относительный путь.\n' >&2
      return 2
      ;;
  esac
  case "/$path/" in
    *"/../"*|*"/./"*|*"//"*)
      printf 'Ошибка: путь содержит запрещённый сегмент: %s\n' "$path" >&2
      return 2
      ;;
  esac
}

home_path() {
  validate_home_relative "$1"
  printf '%s/%s\n' "$HOME" "$1"
}

plutil_run() {
  local tool
  if is_test_mode; then
    tool="${VIBE_MAC_PLUTIL_BIN:-/usr/bin/plutil}"
  else
    tool="/usr/bin/plutil"
  fi
  if [ ! -x "$tool" ]; then
    printf 'Ошибка: plutil недоступен: %s\n' "$tool" >&2
    return 2
  fi
  "$tool" "$@"
}

json_lint() {
  plutil_run -convert json -o /dev/null -- "$1" >/dev/null
}

json_extract_raw() {
  local file keypath
  file="$1"
  keypath="$2"
  plutil_run -extract "$keypath" raw -- "$file"
}

json_extract_typed() {
  local file keypath expected_type
  file="$1"
  keypath="$2"
  expected_type="$3"
  plutil_run -extract "$keypath" raw -expect "$expected_type" -- "$file"
}

json_extract_json() {
  local file keypath expected_type
  file="$1"
  keypath="$2"
  expected_type="${3:-}"
  if [ -n "$expected_type" ]; then
    plutil_run \
      -extract "$keypath" json -expect "$expected_type" -o - -- "$file"
  else
    plutil_run -extract "$keypath" json -o - -- "$file"
  fi
}

home_relative_from_absolute() {
  local target relative
  target="$1"
  case "$target" in
    "$HOME")
      printf '%s\n' .
      return 0
      ;;
    "$HOME"/*)
      relative="${target#"$HOME"/}"
      ;;
    *)
      printf 'Ошибка: путь находится вне HOME allowlist: %s\n' "$target" >&2
      return 2
      ;;
  esac
  validate_home_relative "$relative"
  printf '%s\n' "$relative"
}

validate_home_dir_path() {
  local target relative current remaining segment
  target="$1"
  if [ -L "$HOME" ] || [ ! -d "$HOME" ]; then
    printf 'Ошибка: HOME не является безопасным каталогом.\n' >&2
    return 2
  fi
  relative="$(home_relative_from_absolute "$target")" || return 2
  if [ "$relative" = . ]; then
    return 0
  fi

  current="$HOME"
  remaining="$relative"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*)
        segment="${remaining%%/*}"
        remaining="${remaining#*/}"
        ;;
      *)
        segment="$remaining"
        remaining=
        ;;
    esac
    current="$current/$segment"
    if [ -L "$current" ] ||
      { [ -e "$current" ] && [ ! -d "$current" ]; }; then
      printf 'Ошибка: небезопасный каталог в HOME: %s\n' "$current" >&2
      return 2
    fi
  done
}

ensure_home_dir() {
  local target relative current remaining segment
  target="$1"
  validate_home_dir_path "$target" || return 2
  relative="$(home_relative_from_absolute "$target")" || return 2
  [ "$relative" != . ] || return 0

  current="$HOME"
  remaining="$relative"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*)
        segment="${remaining%%/*}"
        remaining="${remaining#*/}"
        ;;
      *)
        segment="$remaining"
        remaining=
        ;;
    esac
    current="$current/$segment"
    if [ ! -d "$current" ]; then
      umask 077
      /bin/mkdir "$current"
      /bin/chmod 0700 "$current"
    fi
  done
}

private_parent_dir() {
  local target parent
  target="$1"
  parent="${target%/*}"
  if [ "$parent" = "$target" ] || [ -z "$parent" ]; then
    printf 'Ошибка: нужен абсолютный путь с родительским каталогом.\n' >&2
    return 2
  fi
  ensure_home_dir "$parent"
  case "$parent" in
    "$VIBE_MAC_RUNTIME_ROOT"|"$VIBE_MAC_RUNTIME_ROOT"/*|"$VIBE_MAC_BACKUP_ROOT"|"$VIBE_MAC_BACKUP_ROOT"/*)
      /bin/chmod 0700 "$parent"
      ;;
  esac
}

ensure_parent_dir() {
  local target parent
  target="$1"
  parent="${target%/*}"
  if [ "$parent" = "$target" ] || [ -z "$parent" ]; then
    printf 'Ошибка: небезопасный родительский каталог.\n' >&2
    return 2
  fi
  ensure_home_dir "$parent"
}

atomic_copy() {
  local source target temp
  source="$1"
  target="$2"
  private_parent_dir "$target"
  if [ -L "$target" ]; then
    printf 'Ошибка: целевой JSON не может быть symlink: %s\n' "$target" >&2
    return 2
  fi
  temp="$(/usr/bin/mktemp "$target.tmp.XXXXXX")"
  if ! /bin/cp "$source" "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 1
  fi
  /bin/chmod 0600 "$temp"
  if ! json_lint "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/mv -f "$temp" "$target"
}

json_replace_strings_atomic() {
  local file key_one value_one key_two value_two temp
  file="$1"
  key_one="$2"
  value_one="$3"
  key_two="$4"
  value_two="$5"

  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'Ошибка: JSON отсутствует или является symlink: %s\n' "$file" >&2
    return 2
  fi
  temp="$(/usr/bin/mktemp "$file.tmp.XXXXXX")"
  if ! /bin/cp "$file" "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 1
  fi
  if ! plutil_run -replace "$key_one" -string "$value_one" "$temp" >/dev/null; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  if ! plutil_run -replace "$key_two" -string "$value_two" "$temp" >/dev/null; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  if ! json_lint "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  /bin/mv -f "$temp" "$file"
}

json_replace_string_atomic() {
  local file key value temp
  file="$1"
  key="$2"
  value="$3"
  validate_json_keypath "$key"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'Ошибка: JSON отсутствует или является symlink: %s\n' "$file" >&2
    return 2
  fi
  temp="$(/usr/bin/mktemp "$file.tmp.XXXXXX")"
  if ! /bin/cp "$file" "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 1
  fi
  if ! plutil_run -replace "$key" -string "$value" "$temp" >/dev/null; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  if ! json_lint "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  /bin/mv -f "$temp" "$file"
}

validate_json_keypath() {
  case "$1" in
    ""|.*|*.|*..*|*[!A-Za-z0-9_.@-]*)
      printf 'Ошибка: небезопасный JSON key path.\n' >&2
      return 2
      ;;
  esac
}

json_set_json_atomic() {
  local file keypath json_value temp operation
  file="$1"
  keypath="$2"
  json_value="$3"
  validate_json_keypath "$keypath"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'Ошибка: JSON отсутствует или является symlink: %s\n' "$file" >&2
    return 2
  fi
  temp="$(/usr/bin/mktemp "$file.tmp.XXXXXX")"
  /bin/cp "$file" "$temp"
  if plutil_run -extract "$keypath" raw -- "$temp" >/dev/null 2>&1; then
    operation=-replace
  else
    operation=-insert
  fi
  if ! plutil_run "$operation" "$keypath" -json "$json_value" "$temp" >/dev/null; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  if ! json_lint "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  /bin/mv -f "$temp" "$file"
}

manifest_record_package() {
  local kind name preexisting owned owner before after json
  kind="$1"
  name="$2"
  preexisting="$3"
  owned="$4"
  owner="$5"
  before="$6"
  after="$7"
  case "$kind" in formulae|casks) ;; *) return 2 ;; esac
  case "$name" in ""|*[!A-Za-z0-9@._+-]*) return 2 ;; esac
  case "$preexisting:$owned" in
    true:true|true:false|false:true|false:false) ;;
    *) return 2 ;;
  esac
  case "$owner" in homebrew|external|vibe-mac) ;; *) return 2 ;; esac
  if ! printf '%s' "$before$after" |
    LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9@._+,: -]*$'; then
    return 2
  fi
  json="{\"preexisting\":$preexisting,\"owned\":$owned,\"owner\":\"$owner\",\"version_before\":\"$before\",\"version_after\":\"$after\"}"
  json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" "packages.$kind.$name" "$json"
}

manifest_record_dependency_delta() {
  json_set_json_atomic \
    "$VIBE_MAC_MANIFEST_FILE" \
    packages.dependency_delta \
    "$1"
}

manifest_record_file() {
  local id relative kind block_id preexisting owned applied_sha backup_logical
  local backup_dir backup_path backup_kind backup_sha backup_relative
  local json
  id="$1"
  relative="$2"
  kind="$3"
  block_id="$4"
  preexisting="$5"
  owned="$6"
  applied_sha="$7"
  backup_logical="$8"
  validate_logical_id "$id"
  validate_home_relative "$relative"
  case "$kind" in managed_block|owned_file) ;; *) return 2 ;; esac
  case "$preexisting:$owned" in
    true:true|true:false|false:true|false:false) ;;
    *) return 2 ;;
  esac
  if [ "$kind" = managed_block ]; then
    validate_logical_id "$block_id"
  elif [ -n "$block_id" ]; then
    return 2
  fi
  validate_sha256_or_empty "$applied_sha" || return 2
  validate_logical_id "$backup_logical"

  backup_dir="$VIBE_MAC_BACKUP_ROOT/${VIBE_MAC_INSTALL_ID:?install ID не задан}"
  if [ -f "$backup_dir/$backup_logical.before" ] &&
    [ ! -L "$backup_dir/$backup_logical.before" ]; then
    backup_path="$backup_dir/$backup_logical.before"
    backup_kind="file"
  elif [ -f "$backup_dir/$backup_logical.absent" ] &&
    [ ! -L "$backup_dir/$backup_logical.absent" ]; then
    backup_path="$backup_dir/$backup_logical.absent"
    backup_kind="absent"
  else
    printf 'Ошибка: backup evidence для %s отсутствует.\n' "$id" >&2
    return 2
  fi
  backup_relative="${backup_path#"$HOME"/}"
  [ "$backup_relative" != "$backup_path" ] || return 2
  validate_home_relative "$backup_relative"
  backup_sha="$(sha256_file "$backup_path")"
  validate_sha256_or_empty "$backup_sha" || return 2

  json="{\"path_kind\":\"home_relative\",\"path\":\"$relative\",\"kind\":\"$kind\",\"block_id\":\"$block_id\",\"preexisting\":$preexisting,\"owned\":$owned,\"applied_sha\":\"$applied_sha\",\"backup\":{\"path_kind\":\"home_relative\",\"path\":\"$backup_relative\",\"kind\":\"$backup_kind\",\"sha256\":\"$backup_sha\"}}"
  json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" "files.$id" "$json"
}

validate_home_target_ancestors() {
  local relative current remaining segment
  relative="$1"
  validate_home_relative "$relative"
  current="$HOME"
  remaining="$relative"
  while :; do
    case "$remaining" in
      */*)
        segment="${remaining%%/*}"
        remaining="${remaining#*/}"
        current="$current/$segment"
        if [ -L "$current" ] ||
          { [ -e "$current" ] && [ ! -d "$current" ]; }; then
          return 2
        fi
        ;;
      *)
        break
        ;;
    esac
  done
}

manifest_validate_file_entry() {
  local id expected_relative expected_kind expected_block backup_logical
  local path_kind relative kind block_id preexisting owned applied_sha
  local backup_path_kind backup_relative backup_kind backup_sha
  local install_id expected_before expected_absent backup_target actual_sha
  id="$1"
  expected_relative="$2"
  expected_kind="$3"
  expected_block="$4"
  backup_logical="$5"
  if ! json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "files.$id" \
    >/dev/null 2>&1; then
    return 0
  fi
  json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id" dictionary >/dev/null || return 2
  path_kind="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.path_kind" string)" || return 2
  relative="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.path" string)" || return 2
  kind="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.kind" string)" || return 2
  block_id="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.block_id" string)" || return 2
  preexisting="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.preexisting" bool)" || return 2
  owned="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned" bool)" || return 2
  applied_sha="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.applied_sha" string)" || return 2
  [ "$path_kind" = home_relative ] || return 2
  [ "$relative" = "$expected_relative" ] || return 2
  validate_home_relative "$relative" || return 2
  validate_home_target_ancestors "$relative" || return 2
  [ "$kind" = "$expected_kind" ] || return 2
  [ "$block_id" = "$expected_block" ] || return 2
  case "$preexisting:$owned" in
    true:true|true:false|false:true|false:false) ;;
    *) return 2 ;;
  esac
  validate_sha256_or_empty "$applied_sha" && [ -n "$applied_sha" ] ||
    return 2

  json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.backup" dictionary \
    >/dev/null || return 2
  backup_path_kind="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.backup.path_kind" string)" || return 2
  backup_relative="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.backup.path" string)" || return 2
  backup_kind="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.backup.kind" string)" || return 2
  backup_sha="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.backup.sha256" string)" || return 2
  [ "$backup_path_kind" = home_relative ] || return 2
  validate_home_relative "$backup_relative" || return 2
  validate_home_target_ancestors "$backup_relative" || return 2
  install_id="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" install_id string)" || return 2
  validate_logical_id "$install_id" || return 2
  validate_logical_id "$backup_logical" || return 2
  expected_before=".vibe-mac-backup/$install_id/$backup_logical.before"
  expected_absent=".vibe-mac-backup/$install_id/$backup_logical.absent"
  case "$backup_kind:$backup_relative" in
    "file:$expected_before"|"absent:$expected_absent") ;;
    *) return 2 ;;
  esac
  validate_sha256_or_empty "$backup_sha" && [ -n "$backup_sha" ] ||
    return 2
  backup_target="$HOME/$backup_relative"
  [ -f "$backup_target" ] && [ ! -L "$backup_target" ] || return 2
  actual_sha="$(sha256_file "$backup_target")" || return 2
  [ "$actual_sha" = "$backup_sha" ]
}

manifest_record_runtime() {
  local name version preexisting owned json
  name="$1"
  version="$2"
  preexisting="$3"
  owned="$4"
  case "$name" in node|python) ;; *) return 2 ;; esac
  case "$preexisting:$owned" in
    true:true|true:false|false:true|false:false) ;;
    *) return 2 ;;
  esac
  if ! printf '%s' "$version" |
    LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9._+-]+$'; then
    return 2
  fi
  json="{\"version\":\"$version\",\"preexisting\":$preexisting,\"owned\":$owned}"
  json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" "runtimes.$name" "$json"
}

manifest_record_git_default() {
  local id key value json
  id="$1"
  key="$2"
  value="$3"
  validate_logical_id "$id"
  case "$id:$key:$value" in
    init-default-branch:init.defaultBranch:main|\
    pull-rebase:pull.rebase:true|\
    push-auto-upstream:push.autoSetupRemote:true)
      ;;
    *) return 2 ;;
  esac
  json="{\"key\":\"$key\",\"created\":true,\"applied_value\":\"$value\"}"
  json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" "git_defaults.$id" "$json"
}

manifest_record_platform() {
  local architecture macos_version json
  architecture="$1"
  macos_version="$2"
  case "$architecture" in arm64|x86_64) ;; *) return 2 ;; esac
  if ! printf '%s' "$macos_version" |
    LC_ALL=C /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,2}$'; then
    return 2
  fi
  json="{\"architecture\":\"$architecture\",\"macos_version\":\"$macos_version\"}"
  json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" platform "$json"
}

manifest_record_release_from_env() {
  local version archive_sha tree_sha expected_root current_target
  local previous_version previous_json current_json link_json installer_version
  local launcher_id launcher_sha launcher_json temp
  local verify_sha doctor_sha uninstall_sha
  version="${VIBE_MAC_RELEASE_VERSION:-}"
  [ -n "$version" ] || return 0
  archive_sha="${VIBE_MAC_RELEASE_ARCHIVE_SHA256:-}"
  tree_sha="${VIBE_MAC_RELEASE_TREE_SHA256:-}"
  case "$version" in
    [A-Za-z0-9]*)
      case "$version" in *[!A-Za-z0-9._-]*|*..*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  validate_sha256_or_empty "$archive_sha" && [ -n "$archive_sha" ] || return 2
  validate_sha256_or_empty "$tree_sha" && [ -n "$tree_sha" ] || return 2
  expected_root="$VIBE_MAC_RUNTIME_ROOT/releases/$version"
  [ "$VIBE_MAC_ROOT" = "$expected_root" ] || return 2
  [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ] || return 2
  current_target="$(/usr/bin/readlink "$VIBE_MAC_RUNTIME_ROOT/current")" ||
    return 2
  [ "$current_target" = "releases/$version" ] || return 2

  previous_version="$(json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" releases.current.version string 2>/dev/null)" ||
    return 2
  json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" releases.current dictionary \
    >/dev/null 2>&1 || return 2
  if [ -n "$previous_version" ] && [ "$previous_version" != "$version" ]; then
    previous_json="$(json_extract_json \
      "$VIBE_MAC_MANIFEST_FILE" releases.current dictionary 2>/dev/null)" ||
      return 2
  fi
  verify_sha="${VIBE_MAC_LAUNCHER_VERIFY_SHA256:-}"
  doctor_sha="${VIBE_MAC_LAUNCHER_DOCTOR_SHA256:-}"
  uninstall_sha="${VIBE_MAC_LAUNCHER_UNINSTALL_SHA256:-}"
  for launcher_sha in "$verify_sha" "$doctor_sha" "$uninstall_sha"; do
    validate_sha256_or_empty "$launcher_sha" && [ -n "$launcher_sha" ] ||
      return 2
  done
  installer_version="${VIBE_MAC_VERSION:-$version}"
  case "$installer_version" in
    ""|*[!A-Za-z0-9._-]*|*..*) return 2 ;;
  esac
  json_extract_typed \
    "$VIBE_MAC_MANIFEST_FILE" installer_version string \
    >/dev/null 2>&1 || return 2
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] &&
    [ ! -L "$VIBE_MAC_MANIFEST_FILE" ] || return 2

  current_json="{\"version\":\"$version\",\"path_kind\":\"runtime_relative\",\"path\":\"releases/$version\",\"archive_sha256\":\"$archive_sha\",\"tree_sha256\":\"$tree_sha\",\"owned\":true}"
  link_json="{\"path_kind\":\"runtime_relative\",\"path\":\"current\",\"target\":\"releases/$version\",\"owned\":true}"

  temp="$(/usr/bin/mktemp "$VIBE_MAC_MANIFEST_FILE.tmp.XXXXXX")"
  if ! /bin/cp "$VIBE_MAC_MANIFEST_FILE" "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 1
  fi
  if [ -n "${previous_json:-}" ] &&
    ! json_set_json_atomic "$temp" releases.previous "$previous_json"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  if ! json_set_json_atomic "$temp" releases.current "$current_json" ||
    ! json_set_json_atomic "$temp" current_link "$link_json"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi

  for launcher_id in verify doctor uninstall; do
    case "$launcher_id" in
      verify) launcher_sha="$verify_sha" ;;
      doctor) launcher_sha="$doctor_sha" ;;
      uninstall) launcher_sha="$uninstall_sha" ;;
    esac
    launcher_json="{\"path_kind\":\"runtime_relative\",\"path\":\"bin/vibe-mac-$launcher_id\",\"sha256\":\"$launcher_sha\",\"owned\":true}"
    if ! json_set_json_atomic \
      "$temp" "launchers.$launcher_id" "$launcher_json"; then
      /bin/unlink "$temp" 2>/dev/null || true
      return 2
    fi
  done
  if ! plutil_run \
    -replace installer_version -string "$installer_version" "$temp" \
    >/dev/null || ! json_lint "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  /bin/mv -f "$temp" "$VIBE_MAC_MANIFEST_FILE"
}

tree_sha256() {
  local root
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  (
    cd "$root"
    /usr/bin/find . -mindepth 1 -print | LC_ALL=C /usr/bin/sort |
      while IFS= read -r path; do
        case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) exit 2 ;; esac
        if [ -L "$path" ]; then
          exit 2
        elif [ -f "$path" ]; then
          printf 'F\t%s\t%s\t%s\n' \
            "$(file_mode "$path")" "$(sha256_file "$path")" "$path"
        elif [ -d "$path" ]; then
          printf 'D\t%s\t-\t%s\n' "$(file_mode "$path")" "$path"
        else
          exit 2
        fi
      done
  ) | sha256_stdin
}

release_tree_sha256() {
  local root
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  (
    cd "$root"
    /usr/bin/find . -mindepth 1 \
      ! -path './.bundle-sha256' \
      ! -path './.bundle-tree-sha256' \
      -print | LC_ALL=C /usr/bin/sort |
      while IFS= read -r path; do
        case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) exit 2 ;; esac
        if [ -L "$path" ]; then
          exit 2
        elif [ -f "$path" ]; then
          printf 'F\t%s\t%s\t%s\n' \
            "$(file_mode "$path")" "$(sha256_file "$path")" "$path"
        elif [ -d "$path" ]; then
          printf 'D\t%s\t-\t%s\n' "$(file_mode "$path")" "$path"
        else
          exit 2
        fi
      done
  ) | sha256_stdin
}

state_init() {
  local template target schema expected installer_version expected_version
  template="$1"
  target="$2"
  expected="${STATE_SCHEMA_VERSION:-1}"

  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ -L "$target" ] || ! json_lint "$target"; then
      printf 'Ошибка: progress.json повреждён или является symlink.\n' >&2
      return 2
    fi
  else
    atomic_copy "$template" "$target"
  fi

  schema="$(json_extract_typed "$target" schema_version integer)" || {
    printf 'Ошибка: progress schema_version имеет неверный тип.\n' >&2
    return 2
  }
  if [ "$schema" != "$expected" ]; then
    printf 'Ошибка: неизвестная версия progress schema: %s.\n' "$schema" >&2
    return 2
  fi
  installer_version="$(json_extract_typed \
    "$target" installer_version string)" || {
    printf 'Ошибка: progress installer_version имеет неверный тип.\n' >&2
    return 2
  }
  expected_version="${VIBE_MAC_VERSION:-$installer_version}"
  if [ "$installer_version" != "$expected_version" ]; then
    json_replace_string_atomic \
      "$target" installer_version "$expected_version"
  fi
}

state_has_step() {
  json_extract_raw "$1" "steps.$2.status" >/dev/null 2>&1
}

state_get_status() {
  json_extract_raw "$1" "steps.$2.status"
}

state_mark_complete() {
  local file step completed_at
  file="$1"
  step="$2"
  completed_at="$3"
  if ! state_has_step "$file" "$step"; then
    printf 'Ошибка: неизвестный ID шага: %s.\n' "$step" >&2
    return 2
  fi
  json_replace_strings_atomic \
    "$file" \
    "steps.$step.status" completed \
    "steps.$step.completed_at" "$completed_at"
}

manifest_init() {
  local template target schema expected install_id
  local installer_version expected_version
  template="$1"
  target="$2"
  expected="${MANIFEST_SCHEMA_VERSION:-1}"

  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ -L "$target" ] || ! json_lint "$target"; then
      printf 'Ошибка: manifest.json повреждён или является symlink.\n' >&2
      return 2
    fi
  else
    atomic_copy "$template" "$target"
  fi

  schema="$(json_extract_typed "$target" schema_version integer)" || {
    printf 'Ошибка: manifest schema_version имеет неверный тип.\n' >&2
    return 2
  }
  if [ "$schema" != "$expected" ]; then
    printf 'Ошибка: неизвестная версия manifest schema: %s.\n' "$schema" >&2
    return 2
  fi

  installer_version="$(json_extract_typed \
    "$target" installer_version string)" || {
    printf 'Ошибка: manifest installer_version имеет неверный тип.\n' >&2
    return 2
  }
  install_id="$(json_extract_typed "$target" install_id string)" || {
    printf 'Ошибка: manifest install_id имеет неверный тип.\n' >&2
    return 2
  }
  expected_version="${VIBE_MAC_VERSION:-$installer_version}"
  if [ -z "$install_id" ]; then
    install_id="${VIBE_MAC_INSTALL_ID:-$(run_id_now)}"
    json_replace_strings_atomic \
      "$target" install_id "$install_id" \
      installer_version "$expected_version"
  elif [ "$installer_version" != "$expected_version" ]; then
    json_replace_string_atomic \
      "$target" installer_version "$expected_version"
  fi
  VIBE_MAC_INSTALL_ID="$install_id"
  export VIBE_MAC_INSTALL_ID
}

init_runtime_layout() {
  local dir
  for dir in "$VIBE_MAC_RUNTIME_ROOT" "$VIBE_MAC_RUNTIME_ROOT/releases" "$VIBE_MAC_RUNTIME_ROOT/bin" "$VIBE_MAC_STATE_DIR" "$VIBE_MAC_LOG_DIR"; do
    validate_home_dir_path "$dir" || return 2
  done

  umask 077
  for dir in "$VIBE_MAC_RUNTIME_ROOT" "$VIBE_MAC_RUNTIME_ROOT/releases" "$VIBE_MAC_RUNTIME_ROOT/bin" "$VIBE_MAC_STATE_DIR" "$VIBE_MAC_LOG_DIR"; do
    ensure_home_dir "$dir"
    /bin/chmod 0700 "$dir"
  done
}

acquire_lock() {
  if /bin/mkdir "$VIBE_MAC_LOCK_DIR" 2>/dev/null; then
    /bin/chmod 0700 "$VIBE_MAC_LOCK_DIR"
    printf '%s\n' "$$" >"$VIBE_MAC_LOCK_DIR/pid"
    printf '%s\n' "${VIBE_MAC_VERSION:-unknown}" >"$VIBE_MAC_LOCK_DIR/version"
    utc_now >"$VIBE_MAC_LOCK_DIR/started_at"
    /bin/chmod 0600 "$VIBE_MAC_LOCK_DIR/pid" \
      "$VIBE_MAC_LOCK_DIR/version" "$VIBE_MAC_LOCK_DIR/started_at"
    return 0
  fi
  printf 'Ошибка: другой vibe-mac уже работает или остался stale lock.\n' >&2
  printf 'Запусти vibe-mac-doctor для диагностики.\n' >&2
  return 1
}

release_lock() {
  local expected file
  expected="$VIBE_MAC_STATE_DIR/install.lock.d"
  if [ "$VIBE_MAC_LOCK_DIR" != "$expected" ] || [ -L "$VIBE_MAC_LOCK_DIR" ]; then
    return 2
  fi
  if [ ! -d "$VIBE_MAC_LOCK_DIR" ]; then
    return 0
  fi
  for file in pid version started_at; do
    if [ -f "$VIBE_MAC_LOCK_DIR/$file" ] && [ ! -L "$VIBE_MAC_LOCK_DIR/$file" ]; then
      /bin/unlink "$VIBE_MAC_LOCK_DIR/$file"
    fi
  done
  /bin/rmdir "$VIBE_MAC_LOCK_DIR"
}

redact_line() {
  /usr/bin/sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9_]{12,}/[REDACTED_GITHUB]/g' \
    -e 's/sk-[A-Za-z0-9_-]{12,}/[REDACTED_KEY]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED_SLACK]/g' \
    -e 's/((password|passwd|token|api[_-]?key|client[_-]?secret)[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
}

init_log() {
  local stamp
  stamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  VIBE_MAC_LOG_FILE="$VIBE_MAC_LOG_DIR/install-$stamp-$$.log"
  export VIBE_MAC_LOG_FILE
  : >"$VIBE_MAC_LOG_FILE"
  /bin/chmod 0600 "$VIBE_MAC_LOG_FILE"
}

log_event() {
  local level step message safe
  level="$1"
  step="$2"
  message="$3"
  if [ -z "$VIBE_MAC_LOG_FILE" ]; then
    return 0
  fi
  safe="$(printf '%s' "$message" | /usr/bin/tr '\r\n' '  ' | redact_line)"
  printf '%s\t%s\t%s\t%s\n' "$(utc_now)" "$level" "$step" "$safe" >>"$VIBE_MAC_LOG_FILE"
}

retry() {
  local attempt status delays delay_one delay_two delay
  attempt=1
  delays="${VIBE_MAC_RETRY_DELAYS:-1 2}"
  delay_one="${delays%% *}"
  delay_two="${delays#* }"

  while [ "$attempt" -le 3 ]; do
    if "$@"; then
      return 0
    else
      status="$?"
    fi
    if [ "$attempt" -ge 3 ]; then
      return "$status"
    fi
    if [ "$attempt" -eq 1 ]; then
      delay="$delay_one"
    else
      delay="$delay_two"
    fi
    case "$delay" in
      ''|*[!0-9]*)
        printf 'Ошибка: некорректная задержка retry.\n' >&2
        return 2
        ;;
    esac
    if [ "$delay" -gt 0 ]; then
      /bin/sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

download_once() {
  local url target curl_bin run_user
  url="$1"
  target="$2"
  if is_test_mode && [ -n "${VIBE_MAC_CURL_BIN:-}" ]; then
    curl_bin="$VIBE_MAC_CURL_BIN"
    run_user="$(/usr/bin/id -un)" || return 2
    /usr/bin/env -i \
      HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      TMPDIR="${TMPDIR:-/tmp}" LC_ALL=C \
      VIBE_MAC_ARCHIVE_SOURCE="${VIBE_MAC_ARCHIVE_SOURCE:-}" \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      "$curl_bin" -q \
        --proto '=https' \
        --tlsv1.2 \
        --fail \
        --location \
        --silent \
        --show-error \
        --connect-timeout 15 \
        --max-time 300 \
        --output "$target" \
        "$url"
    return
  fi
  curl_bin=/usr/bin/curl
  run_user="$(/usr/bin/id -un)" || return 2
  /usr/bin/env -i \
    HOME="$HOME" USER="$run_user" LOGNAME="$run_user" SHELL=/bin/zsh \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp LC_ALL=C \
    CURL_HOME=/var/empty \
    "$curl_bin" -q \
    --proto '=https' \
    --tlsv1.2 \
    --fail \
    --location \
    --silent \
    --show-error \
    --connect-timeout 15 \
    --max-time 300 \
    --output "$target" \
    "$url"
}

safe_download() {
  local url target expected actual
  url="$1"
  target="$2"
  expected="$3"
  case "$url" in
    https://*)
      ;;
    *)
      printf 'Ошибка: разрешены только HTTPS-загрузки.\n' >&2
      return 2
      ;;
  esac
  if [ -L "$target" ]; then
    printf 'Ошибка: download target не может быть symlink.\n' >&2
    return 2
  fi
  retry download_once "$url" "$target"
  actual="$(sha256_file "$target")"
  if [ "$actual" != "$expected" ]; then
    /bin/unlink "$target" 2>/dev/null || true
    printf 'Ошибка: SHA-256 загруженного файла не совпал.\n' >&2
    return 2
  fi
}

configure_homebrew_path() {
  if is_test_mode; then
    return 0
  fi
  if [ -x /opt/homebrew/bin/brew ]; then
    PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
  elif [ -x /usr/local/bin/brew ]; then
    PATH="/usr/local/bin:/usr/local/sbin:$PATH"
  fi
  export PATH
}

file_mode() {
  local file
  file="$1"
  if /usr/bin/stat -f '%Lp' "$file" >/dev/null 2>&1; then
    /usr/bin/stat -f '%Lp' "$file"
  else
    /usr/bin/stat -c '%a' "$file"
  fi
}

validate_logical_id() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*)
      printf 'Ошибка: небезопасный logical ID: %s.\n' "$1" >&2
      return 2
      ;;
  esac
}

backup_evidence_kind() {
  local logical install_id backup_dir backup absent backup_present absent_present
  logical="$1"
  validate_logical_id "$logical"
  install_id="${VIBE_MAC_INSTALL_ID:-}"
  validate_logical_id "$install_id"
  backup_dir="$VIBE_MAC_BACKUP_ROOT/$install_id"
  backup="$backup_dir/$logical.before"
  absent="$backup_dir/$logical.absent"
  validate_home_dir_path "$backup_dir" || return 2

  backup_present=0
  absent_present=0
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    backup_present=1
  fi
  if [ -e "$absent" ] || [ -L "$absent" ]; then
    absent_present=1
  fi
  if [ "$backup_present" -eq 1 ] && [ "$absent_present" -eq 1 ]; then
    printf 'Ошибка: найдены противоречивые backup evidence для %s.\n' "$logical" >&2
    return 2
  fi
  if [ "$backup_present" -eq 1 ]; then
    if [ ! -f "$backup" ] || [ -L "$backup" ]; then
      printf 'Ошибка: backup evidence небезопасен: %s\n' "$backup" >&2
      return 2
    fi
    printf '%s\n' file
    return 0
  fi
  if [ "$absent_present" -eq 1 ]; then
    if [ ! -f "$absent" ] || [ -L "$absent" ]; then
      printf 'Ошибка: backup evidence небезопасен: %s\n' "$absent" >&2
      return 2
    fi
    printf '%s\n' absent
    return 0
  fi
  return 1
}

backup_evidence_path() {
  local logical kind status
  logical="$1"
  if kind="$(backup_evidence_kind "$logical")"; then
    :
  else
    status="$?"
    return "$status"
  fi
  case "$kind" in
    file)
      printf '%s/%s/%s.before\n' "$VIBE_MAC_BACKUP_ROOT" "$VIBE_MAC_INSTALL_ID" "$logical"
      ;;
    absent)
      printf '%s/%s/%s.absent\n' "$VIBE_MAC_BACKUP_ROOT" "$VIBE_MAC_INSTALL_ID" "$logical"
      ;;
    *)
      return 2
      ;;
  esac
}

backup_file_once() {
  local source logical install_id backup_dir backup absent kind status source_parent
  source="$1"
  logical="$2"
  validate_logical_id "$logical"
  install_id="${VIBE_MAC_INSTALL_ID:-}"
  validate_logical_id "$install_id"
  backup_dir="$VIBE_MAC_BACKUP_ROOT/$install_id"
  backup="$backup_dir/$logical.before"
  absent="$backup_dir/$logical.absent"

  home_relative_from_absolute "$source" >/dev/null || return 2
  source_parent="${source%/*}"
  validate_home_dir_path "$source_parent" || return 2
  validate_home_dir_path "$VIBE_MAC_BACKUP_ROOT" || return 2
  validate_home_dir_path "$backup_dir" || return 2
  umask 077
  ensure_home_dir "$VIBE_MAC_BACKUP_ROOT"
  ensure_home_dir "$backup_dir"
  /bin/chmod 0700 "$VIBE_MAC_BACKUP_ROOT" "$backup_dir"

  if kind="$(backup_evidence_kind "$logical")"; then
    backup_evidence_path "$logical"
    return 0
  else
    status="$?"
    [ "$status" -eq 1 ] || return 2
  fi

  if [ -L "$source" ]; then
    printf 'Ошибка: backup source является symlink: %s.\n' "$source" >&2
    return 2
  fi
  if [ -f "$source" ]; then
    /bin/cp -p "$source" "$backup"
    /bin/chmod 0600 "$backup"
    printf '%s\n' "$backup"
  elif [ ! -e "$source" ]; then
    : >"$absent"
    /bin/chmod 0600 "$absent"
    printf '%s\n' "$absent"
  else
    printf 'Ошибка: backup source не является обычным файлом: %s.\n' "$source" >&2
    return 2
  fi
}

managed_block_preflight() {
  local target block_id begin end begin_count end_count parent
  target="$1"
  block_id="$2"
  validate_logical_id "$block_id"
  home_relative_from_absolute "$target" >/dev/null || return 2
  parent="${target%/*}"
  validate_home_dir_path "$parent" || return 2
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"

  if [ -L "$target" ]; then
    printf 'Ошибка: managed target является symlink: %s.\n' "$target" >&2
    return 2
  fi
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    printf 'Ошибка: managed target не является обычным файлом: %s.\n' "$target" >&2
    return 2
  fi

  begin_count=0
  end_count=0
  if [ -f "$target" ]; then
    begin_count="$(/usr/bin/grep -Fxc "$begin" "$target" || true)"
    end_count="$(/usr/bin/grep -Fxc "$end" "$target" || true)"
  fi
  if [ "$begin_count" -ne "$end_count" ] || [ "$begin_count" -gt 1 ]; then
    printf 'Ошибка: malformed managed block в %s.\n' "$target" >&2
    return 2
  fi
}

zshrc_has_external_omz_source() {
  local target block_id begin end
  target="$1"
  block_id="$2"
  validate_logical_id "$block_id" || return 2
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"
  /usr/bin/awk -v begin="$begin" -v end="$end" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    inside { next }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      if (line == "}" || line == ")" ||
        line ~ /^(fi|done|esac)($|[;[:space:]])/) {
        if (depth > 0) depth--
        next
      }
      function_open = line ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/ &&
        line ~ /\{[[:space:]]*$/
      if (line ~ /^(if|for|while|until|select|case|function)[[:space:]]/ ||
        function_open || line == "{" || line == "(") {
        depth++
        next
      }
      if (depth != 0) next
      if (line == "source \"$ZSH/oh-my-zsh.sh\"" ||
        line == "source $ZSH/oh-my-zsh.sh" ||
        line == "source \"${ZSH}/oh-my-zsh.sh\"" ||
        line == "source \"$HOME/.oh-my-zsh/oh-my-zsh.sh\"" ||
        line == "source $HOME/.oh-my-zsh/oh-my-zsh.sh" ||
        line == "source ~/.oh-my-zsh/oh-my-zsh.sh" ||
        line == ". \"$ZSH/oh-my-zsh.sh\"" ||
        line == ". $ZSH/oh-my-zsh.sh" ||
        line == ". \"$HOME/.oh-my-zsh/oh-my-zsh.sh\"" ||
        line == ". $HOME/.oh-my-zsh/oh-my-zsh.sh" ||
        line == ". ~/.oh-my-zsh/oh-my-zsh.sh") found = 1
    }
    END { exit !found }
  ' "$target"
}

managed_block_upsert() {
  local target block_id content logical begin end
  local parent temp mode
  target="$1"
  block_id="$2"
  content="$3"
  logical="$4"
  validate_logical_id "$block_id"
  validate_logical_id "$logical"
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"
  managed_block_preflight "$target" "$block_id"

  parent="${target%/*}"
  ensure_parent_dir "$target"
  temp="$(/usr/bin/mktemp "$parent/.vibe-mac-block.XXXXXX")"

  if [ -f "$target" ]; then
    if ! /usr/bin/awk -v begin="$begin" -v end="$end" '
      $0 == begin {
        if (inside || seen) exit 40
        inside = 1
        seen = 1
        next
      }
      $0 == end {
        if (!inside) exit 41
        inside = 0
        next
      }
      !inside { print }
      END {
        if (inside) exit 42
      }
    ' "$target" >"$temp"; then
      /bin/unlink "$temp" 2>/dev/null || true
      printf 'Ошибка: не удалось разобрать managed block.\n' >&2
      return 2
    fi
    mode="$(file_mode "$target")"
  else
    : >"$temp"
    mode=600
  fi

  {
    printf '%s\n' "$begin"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
  } >>"$temp"

  if [ -f "$target" ] && /usr/bin/cmp -s "$target" "$temp"; then
    /bin/unlink "$temp"
    return 0
  fi

  if ! backup_file_once "$target" "$logical" >/dev/null; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod "$mode" "$temp"
  /bin/mv -f "$temp" "$target"
}

install_file_if_absent() {
  local source target logical parent temp
  source="$1"
  target="$2"
  logical="$3"
  validate_logical_id "$logical"
  home_relative_from_absolute "$target" >/dev/null || return 2
  parent="${target%/*}"
  validate_home_dir_path "$parent" || return 2
  if [ ! -f "$source" ] || [ -L "$source" ]; then
    printf 'Ошибка: template отсутствует или небезопасен: %s.\n' "$source" >&2
    return 2
  fi
  if [ -L "$target" ]; then
    printf 'Ошибка: config target является symlink: %s.\n' "$target" >&2
    return 2
  fi
  if [ -e "$target" ]; then
    [ -f "$target" ]
    return
  fi

  ensure_parent_dir "$target"
  backup_file_once "$target" "$logical" >/dev/null
  temp="$(/usr/bin/mktemp "$parent/.vibe-mac-file.XXXXXX")"
  if ! /bin/cp "$source" "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 1
  fi
  /bin/chmod 0600 "$temp"
  /bin/mv -f "$temp" "$target"
}

remove_temp_tree() {
  local target base
  target="$1"
  base="${TMPDIR:-/tmp}"
  case "$target" in
    "$base"/vibe-mac.*|"$base"/vibe-mac-*)
      ;;
    *)
      printf 'Ошибка: отказ от очистки неожиданного temp path.\n' >&2
      return 2
      ;;
  esac
  if [ ! -d "$target" ] || [ -L "$target" ]; then
    return 2
  fi
  /usr/bin/find "$target" -depth -delete
}
