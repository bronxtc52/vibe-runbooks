#!/usr/bin/env bash
set -euo pipefail

: "${HOME:?HOME не задан}"

VIBE_MAC_RUNTIME_ROOT="${VIBE_MAC_RUNTIME_ROOT:-$HOME/.vibe-mac}"
VIBE_MAC_BACKUP_ROOT="${VIBE_MAC_BACKUP_ROOT:-$HOME/.vibe-mac-backup}"
VIBE_MAC_STATE_DIR="${VIBE_MAC_STATE_DIR:-$VIBE_MAC_RUNTIME_ROOT/state}"
VIBE_MAC_LOG_DIR="${VIBE_MAC_LOG_DIR:-$VIBE_MAC_RUNTIME_ROOT/logs}"
VIBE_MAC_STATE_FILE="${VIBE_MAC_STATE_FILE:-$VIBE_MAC_STATE_DIR/progress.json}"
VIBE_MAC_MANIFEST_FILE="${VIBE_MAC_MANIFEST_FILE:-$VIBE_MAC_STATE_DIR/manifest.json}"
VIBE_MAC_LOCK_DIR="${VIBE_MAC_LOCK_DIR:-$VIBE_MAC_STATE_DIR/install.lock.d}"
VIBE_MAC_LOG_FILE="${VIBE_MAC_LOG_FILE:-}"

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

validate_home_relative() {
  local path
  path="$1"
  case "$path" in
    ""|/*|*\\*|*$'\n'*|*$'\r'*)
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
  plutil_run -lint "$1" >/dev/null
}

json_extract_raw() {
  local file keypath
  file="$1"
  keypath="$2"
  plutil_run -extract "$keypath" raw -- "$file"
}

private_parent_dir() {
  local target parent
  target="$1"
  parent="${target%/*}"
  if [ "$parent" = "$target" ] || [ -z "$parent" ]; then
    printf 'Ошибка: нужен абсолютный путь с родительским каталогом.\n' >&2
    return 2
  fi
  umask 077
  /bin/mkdir -p "$parent"
  /bin/chmod 0700 "$parent"
}

ensure_parent_dir() {
  local target parent
  target="$1"
  parent="${target%/*}"
  if [ "$parent" = "$target" ] || [ -z "$parent" ] || [ -L "$parent" ]; then
    printf 'Ошибка: небезопасный родительский каталог.\n' >&2
    return 2
  fi
  if [ ! -d "$parent" ]; then
    umask 077
    /bin/mkdir -p "$parent"
    /bin/chmod 0700 "$parent"
  fi
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
  local file key value current_key current
  file="$1"
  key="$2"
  value="$3"
  current_key="$4"
  current="$(json_extract_raw "$file" "$current_key")"
  json_replace_strings_atomic "$file" "$key" "$value" "$current_key" "$current"
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

state_init() {
  local template target schema expected
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

  schema="$(json_extract_raw "$target" schema_version)"
  if [ "$schema" != "$expected" ]; then
    printf 'Ошибка: неизвестная версия progress schema: %s.\n' "$schema" >&2
    return 2
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

  schema="$(json_extract_raw "$target" schema_version)"
  if [ "$schema" != "$expected" ]; then
    printf 'Ошибка: неизвестная версия manifest schema: %s.\n' "$schema" >&2
    return 2
  fi

  install_id="$(json_extract_raw "$target" install_id)"
  if [ -z "$install_id" ]; then
    install_id="${VIBE_MAC_INSTALL_ID:-$(run_id_now)}"
    json_replace_string_atomic "$target" install_id "$install_id" schema_version
  fi
  VIBE_MAC_INSTALL_ID="$install_id"
  export VIBE_MAC_INSTALL_ID
}

init_runtime_layout() {
  umask 077
  /bin/mkdir -p \
    "$VIBE_MAC_RUNTIME_ROOT" \
    "$VIBE_MAC_RUNTIME_ROOT/releases" \
    "$VIBE_MAC_RUNTIME_ROOT/bin" \
    "$VIBE_MAC_STATE_DIR" \
    "$VIBE_MAC_LOG_DIR"
  /bin/chmod 0700 \
    "$VIBE_MAC_RUNTIME_ROOT" \
    "$VIBE_MAC_RUNTIME_ROOT/releases" \
    "$VIBE_MAC_RUNTIME_ROOT/bin" \
    "$VIBE_MAC_STATE_DIR" \
    "$VIBE_MAC_LOG_DIR"
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
  local url target curl_bin
  url="$1"
  target="$2"
  if is_test_mode && [ -n "${VIBE_MAC_CURL_BIN:-}" ]; then
    curl_bin="$VIBE_MAC_CURL_BIN"
  else
    curl_bin="/usr/bin/curl"
  fi
  "$curl_bin" \
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

backup_file_once() {
  local source logical install_id backup_dir backup absent
  source="$1"
  logical="$2"
  validate_logical_id "$logical"
  install_id="${VIBE_MAC_INSTALL_ID:-}"
  validate_logical_id "$install_id"
  backup_dir="$VIBE_MAC_BACKUP_ROOT/$install_id"
  backup="$backup_dir/$logical.before"
  absent="$backup_dir/$logical.absent"

  umask 077
  /bin/mkdir -p "$backup_dir"
  /bin/chmod 0700 "$VIBE_MAC_BACKUP_ROOT" "$backup_dir"

  if [ -e "$backup" ] || [ -e "$absent" ]; then
    if [ -e "$backup" ]; then
      printf '%s\n' "$backup"
    else
      printf '%s\n' "$absent"
    fi
    return 0
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

managed_block_upsert() {
  local target block_id content logical begin end begin_count end_count
  local parent temp mode
  target="$1"
  block_id="$2"
  content="$3"
  logical="$4"
  validate_logical_id "$block_id"
  validate_logical_id "$logical"
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

  backup_file_once "$target" "$logical" >/dev/null
  /bin/chmod "$mode" "$temp"
  /bin/mv -f "$temp" "$target"
}

install_file_if_absent() {
  local source target logical parent temp
  source="$1"
  target="$2"
  logical="$3"
  validate_logical_id "$logical"
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

  parent="${target%/*}"
  ensure_parent_dir "$target"
  backup_file_once "$target" "$logical" >/dev/null
  temp="$(/usr/bin/mktemp "$parent/.vibe-mac-file.XXXXXX")"
  /bin/cp "$source" "$temp"
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
