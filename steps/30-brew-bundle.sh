#!/usr/bin/env bash
set -euo pipefail

STEP_PATH="$(/bin/realpath "$0" 2>/dev/null)" || exit 2
STEP_DIR="${STEP_PATH%/*}"
VIBE_MAC_ROOT="${STEP_DIR%/*}"
export VIBE_MAC_ROOT

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

BREW_TEMP_DIR=
VIBE_MAC_VERIFY_RECEIPTS=0

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

step_applications_root() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_APPLICATIONS_ROOT:-}" ]; then
    case "$VIBE_MAC_TEST_APPLICATIONS_ROOT" in
      /*)
        case "$VIBE_MAC_TEST_APPLICATIONS_ROOT" in
          *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;;
        esac
        printf '%s\n' "$VIBE_MAC_TEST_APPLICATIONS_ROOT"
        return 0
        ;;
      *) return 2 ;;
    esac
  fi
  printf '%s\n' /Applications
}

required_homebrew_executable() {
  local name prefix candidate status
  name="$1"
  case "$name" in
    brew|git|gh|starship|rg|fd|fzf|bat|eza|jq|tree|zoxide|mise|uv|\
      claude|codex|cursor-agent)
      ;;
    *) return 2 ;;
  esac
  prefix="$(step_expected_homebrew_prefix)" || return 2
  homebrew_env_files_safe "$prefix" || return 2
  status=0
  candidate="$(homebrew_executable_in_prefix "$prefix" "$name")" || status="$?"
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$candidate"
}

brew_run() {
  local brew_bin prefix clean_path run_user config_home run_home run_tmp
  brew_bin="$(required_homebrew_executable brew)" || return "$?"
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  config_home=/var/empty
  [ -d "$config_home" ] && [ ! -L "$config_home" ] || return 2
  case "$VIBE_MAC_VERIFY_RECEIPTS" in
    0)
      run_home="$HOME"
      if is_test_mode; then
        run_tmp="${TMPDIR:-/tmp}"
      else
        run_tmp=/tmp
      fi
      ;;
    1)
      run_home=/var/empty
      run_tmp=/var/empty
      ;;
    *) return 2 ;;
  esac

  if is_test_mode; then
    /usr/bin/env -i \
      HOME="$run_home" \
      USER="$run_user" \
      LOGNAME="$run_user" \
      SHELL=/bin/zsh \
      PATH="$clean_path" \
      TMPDIR="$run_tmp" \
      LC_ALL=C \
      DO_NOT_TRACK=1 \
      GH_TELEMETRY=disabled \
      DISABLE_AUTOUPDATER=1 \
      DISABLE_TELEMETRY=1 \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_INSTALL_UPGRADE=1 \
      HOMEBREW_NO_INSTALL_CLEANUP=1 \
      HOMEBREW_NO_ANALYTICS=1 \
      HOMEBREW_NO_ENV_HINTS=1 \
      HOMEBREW_BUNDLE_NO_UPGRADE=1 \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      CURL_HOME="$config_home" \
      XDG_CONFIG_HOME="$config_home" \
      HOMEBREW_BUNDLE_BREW_SKIP="${HOMEBREW_BUNDLE_BREW_SKIP:-}" \
      HOMEBREW_BUNDLE_CASK_SKIP="${HOMEBREW_BUNDLE_CASK_SKIP:-}" \
      VIBE_MAC_EVENT_LOG="${VIBE_MAC_EVENT_LOG:-}" \
      VIBE_MAC_TEST_VERIFY_FIXTURE_HOME="${VIBE_MAC_TEST_VERIFY_FIXTURE_HOME:-}" \
      VIBE_MAC_TEST_BUNDLE_MARKER="${VIBE_MAC_TEST_BUNDLE_MARKER:-}" \
      VIBE_MAC_FAKE_FORMULAE="${VIBE_MAC_FAKE_FORMULAE:-}" \
      VIBE_MAC_FAKE_CASKS="${VIBE_MAC_FAKE_CASKS:-}" \
      VIBE_MAC_FAKE_NEW_FORMULAE="${VIBE_MAC_FAKE_NEW_FORMULAE:-}" \
      VIBE_MAC_FAKE_NEW_CASKS="${VIBE_MAC_FAKE_NEW_CASKS:-}" \
      VIBE_MAC_FAKE_CHANGE_DIRECT="${VIBE_MAC_FAKE_CHANGE_DIRECT:-0}" \
      VIBE_MAC_FAKE_CHANGE_DEP="${VIBE_MAC_FAKE_CHANGE_DEP:-0}" \
      VIBE_MAC_FAKE_BUNDLE_FAIL="${VIBE_MAC_FAKE_BUNDLE_FAIL:-0}" \
      VIBE_MAC_FAKE_SKIP_MARKER="${VIBE_MAC_FAKE_SKIP_MARKER:-0}" \
      VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND="${VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND:-}" \
      "$brew_bin" "$@"
    return
  fi

  /usr/bin/env -i \
    HOME="$run_home" \
    USER="$run_user" \
    LOGNAME="$run_user" \
    SHELL=/bin/zsh \
    PATH="$clean_path" \
    TMPDIR="$run_tmp" \
    LC_ALL=C \
    DO_NOT_TRACK=1 \
    GH_TELEMETRY=disabled \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_INSTALL_UPGRADE=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_BUNDLE_NO_UPGRADE=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    CURL_HOME="$config_home" \
    XDG_CONFIG_HOME="$config_home" \
    HOMEBREW_BUNDLE_BREW_SKIP="${HOMEBREW_BUNDLE_BREW_SKIP:-}" \
    HOMEBREW_BUNDLE_CASK_SKIP="${HOMEBREW_BUNDLE_CASK_SKIP:-}" \
    "$brew_bin" "$@"
}

application_present() {
  local name root target
  name="$1"
  root="$(step_applications_root)" || return 2
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  case "$name" in
    ghostty) target="$root/Ghostty.app" ;;
    cursor) target="$root/Cursor.app" ;;
    zed) target="$root/Zed.app" ;;
    raycast) target="$root/Raycast.app" ;;
    visual-studio-code) target="$root/Visual Studio Code.app" ;;
    *) return 2 ;;
  esac
  macos_app_bundle_ready "$target"
}

formulae() {
  printf '%s\n' \
    git gh starship ripgrep fd fzf bat eza jq tree zoxide mise uv
}

casks() {
  printf '%s\n' \
    ghostty font-jetbrains-mono-nerd-font claude-code codex cursor cursor-cli
}

extra_casks() {
  printf '%s\n' zed raycast visual-studio-code
}

formula_command() {
  case "$1" in
    git) printf '%s\n' git ;;
    gh) printf '%s\n' gh ;;
    starship) printf '%s\n' starship ;;
    ripgrep) printf '%s\n' rg ;;
    fd) printf '%s\n' fd ;;
    fzf) printf '%s\n' fzf ;;
    bat) printf '%s\n' bat ;;
    eza) printf '%s\n' eza ;;
    jq) printf '%s\n' jq ;;
    tree) printf '%s\n' tree ;;
    zoxide) printf '%s\n' zoxide ;;
    mise) printf '%s\n' mise ;;
    uv) printf '%s\n' uv ;;
    *) return 2 ;;
  esac
}

font_present() {
  local font_dir
  font_dir="$HOME/Library/Fonts"
  font_dir_has_jetbrains_mono_nerd_font "$font_dir"
}

formula_preexisting() {
  local name
  name="$1"
  brew_run list --formula "$name" >/dev/null 2>&1
}

cask_preexisting() {
  local name status
  name="$1"
  status=0
  brew_run list --cask "$name" >/dev/null 2>&1 || status="$?"
  case "$status" in
    0) return 0 ;;
    1) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  case "$name" in
    ghostty|cursor|zed|raycast|visual-studio-code)
      application_present "$name"
      ;;
    font-jetbrains-mono-nerd-font)
      font_present
      ;;
    claude-code|codex|cursor-cli) return 1 ;;
    *)
      return 2
      ;;
  esac
}

build_skip_lists() {
  local name status
  FORMULA_SKIP=
  CASK_SKIP=
  for name in $(formulae); do
    status=0
    formula_preexisting "$name" || status="$?"
    case "$status" in
      0) FORMULA_SKIP="${FORMULA_SKIP:+$FORMULA_SKIP }$name" ;;
      1) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
  done
  for name in $(casks); do
    status=0
    cask_preexisting "$name" || status="$?"
    case "$status" in
      0) CASK_SKIP="${CASK_SKIP:+$CASK_SKIP }$name" ;;
      1) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
  done
  if [ "${EXTRAS:-0}" = "1" ]; then
    for name in $(extra_casks); do
      status=0
      cask_preexisting "$name" || status="$?"
      case "$status" in
        0) CASK_SKIP="${CASK_SKIP:+$CASK_SKIP }$name" ;;
        1) ;;
        2) return 2 ;;
        *) return 1 ;;
      esac
    done
  fi
  export FORMULA_SKIP CASK_SKIP
}

formula_capabilities_ready() {
  local name command_name status
  for name in $(formulae); do
    command_name="$(formula_command "$name")"
    status=0
    required_homebrew_executable "$command_name" >/dev/null || status="$?"
    [ "$status" -eq 0 ] || return "$status"
  done
}

command_version_ready() {
  local command_name command_path output prefix clean_path run_user safe_cwd
  local status
  local -a clean_env
  command_name="$1"
  status=0
  command_path="$(required_homebrew_executable "$command_name")" || status="$?"
  [ "$status" -eq 0 ] || return "$status"
  prefix="$(step_expected_homebrew_prefix)" || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
  safe_cwd="$(cd /var/empty && pwd -P)" || return 2
  clean_env=(
    /usr/bin/env -i
    HOME=/var/empty
    "USER=$run_user"
    "LOGNAME=$run_user"
    SHELL=/bin/zsh
    "PATH=$clean_path"
    TMPDIR=/var/empty
    LANG=C
    LC_ALL=C
    NO_COLOR=1
    DO_NOT_TRACK=1
    GH_TELEMETRY=disabled
    HOMEBREW_NO_ANALYTICS=1
    HOMEBREW_NO_AUTO_UPDATE=1
    HOMEBREW_NO_INSTALL_UPGRADE=1
    HOMEBREW_NO_INSTALL_CLEANUP=1
    HOMEBREW_NO_ENV_HINTS=1
    DISABLE_AUTOUPDATER=1
    DISABLE_TELEMETRY=1
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    MISE_AUTO_INSTALL=0
    MISE_EXEC_AUTO_INSTALL=0
    MISE_OFFLINE=1
  )
  if is_test_mode; then
    clean_env+=(
      "VIBE_MAC_EVENT_LOG=${VIBE_MAC_EVENT_LOG:-}"
      "VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND=${VIBE_MAC_FAKE_BROKEN_VERSION_COMMAND:-}"
    )
  fi
  output="$(
    cd "$safe_cwd"
    "${clean_env[@]}" "$command_path" --version 2>&1
  )" || return 1
  [ -n "$output" ]
}

formula_versions_ready() {
  local name command_name status
  for name in $(formulae); do
    command_name="$(formula_command "$name")"
    status=0
    command_version_ready "$command_name" || status="$?"
    [ "$status" -eq 0 ] || return "$status"
  done
}

cask_cli_versions_ready() {
  local command_name status
  for command_name in claude codex cursor-agent; do
    status=0
    command_version_ready "$command_name" || status="$?"
    [ "$status" -eq 0 ] || return "$status"
  done
}

formula_receipts_ready() {
  local name status
  for name in $(formulae); do
    status=0
    brew_run list --formula "$name" >/dev/null 2>&1 || status="$?"
    case "$status" in
      0) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
  done
}

cask_capabilities_ready() {
  application_present ghostty || return "$?"
  font_present || return "$?"
  required_homebrew_executable claude >/dev/null || return "$?"
  required_homebrew_executable codex >/dev/null || return "$?"
  application_present cursor || return "$?"
  required_homebrew_executable cursor-agent >/dev/null || return "$?"
}

cask_receipts_or_external_ready() {
  local name names status
  names="$(casks)"
  if [ "${EXTRAS:-0}" = "1" ]; then
    names="$names
$(extra_casks)"
  fi
  for name in $names; do
    status=0
    cask_preexisting "$name" || status="$?"
    [ "$status" -eq 0 ] || return "$status"
  done
}

bundle_receipts_ready() {
  required_homebrew_executable brew >/dev/null &&
    formula_receipts_ready &&
    cask_receipts_or_external_ready
}

extras_ready() {
  [ "${EXTRAS:-0}" = "1" ] || return 0
  application_present zed || return "$?"
  application_present raycast || return "$?"
  application_present visual-studio-code || return "$?"
}

bundle_ready() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_BUNDLE_MARKER:-}" ]; then
    [ -f "$VIBE_MAC_TEST_BUNDLE_MARKER" ]
    return
  fi
  required_homebrew_executable brew >/dev/null || return "$?"
  formula_capabilities_ready || return "$?"
  cask_capabilities_ready || return "$?"
  extras_ready || return "$?"
  if [ "${DRY_RUN:-0}" = "1" ] &&
    [ "${VIBE_MAC_FULL_VERIFY:-0}" != "1" ]; then
    return 0
  fi
  bundle_receipts_ready || return "$?"
  formula_versions_ready || return "$?"
  cask_cli_versions_ready
}

cleanup_brew_temp() {
  if [ -n "$BREW_TEMP_DIR" ] && [ -d "$BREW_TEMP_DIR" ]; then
    remove_temp_tree "$BREW_TEMP_DIR" || true
  fi
  BREW_TEMP_DIR=
}

assert_direct_versions_unchanged() {
  local before after name before_line after_line
  before="$1"
  after="$2"
  for name in $(formulae); do
    before_line="$(/usr/bin/awk -v name="$name" '$1 == name {print; exit}' "$before")"
    [ -n "$before_line" ] || continue
    after_line="$(/usr/bin/awk -v name="$name" '$1 == name {print; exit}' "$after")"
    if [ "$before_line" != "$after_line" ]; then
      ui_fail "Homebrew изменил прямой preexisting package: $name."
      return 1
    fi
  done
}

assert_direct_cask_versions_unchanged() {
  local before after name before_line after_line names
  before="$1"
  after="$2"
  names="$(casks)"
  if [ "${EXTRAS:-0}" = "1" ]; then
    names="$names
$(extra_casks)"
  fi
  for name in $names; do
    before_line="$(/usr/bin/awk -v name="$name" '$1 == name {print; exit}' "$before")"
    [ -n "$before_line" ] || continue
    after_line="$(/usr/bin/awk -v name="$name" '$1 == name {print; exit}' "$after")"
    if [ "$before_line" != "$after_line" ]; then
      ui_fail "Homebrew изменил прямой preexisting cask: $name."
      return 1
    fi
  done
}

snapshot_version() {
  local file name
  file="$1"
  name="$2"
  /usr/bin/awk -v name="$name" '
    $1 == name {
      sub(/^[^ ]+[ ]*/, "")
      print
      exit
    }
  ' "$file"
}

word_in_list() {
  local word list
  word="$1"
  list="$2"
  case " $list " in
    *" $word "*) return 0 ;;
    *) return 1 ;;
  esac
}

manifest_package_recorded() {
  local kind name owned
  kind="$1"
  name="$2"
  if owned="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" \
    "packages.$kind.$name.owned" 2>/dev/null)"; then
    case "$owned" in true|false) return 0 ;; *) return 2 ;; esac
  fi
  if json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" \
    "packages.$kind.$name" >/dev/null 2>&1; then
    return 2
  fi
  return 1
}

record_packages() {
  local before_formula after_formula before_cask after_cask
  local name before after preexisting owned owner names history_status
  before_formula="$1"
  after_formula="$2"
  before_cask="$3"
  after_cask="$4"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0

  for name in $(formulae); do
    history_status=0
    manifest_package_recorded formulae "$name" || history_status="$?"
    case "$history_status" in
      0) continue ;;
      1) ;;
      *) return 2 ;;
    esac
    before="$(snapshot_version "$before_formula" "$name")"
    after="$(snapshot_version "$after_formula" "$name")"
    if [ -n "$before" ]; then
      preexisting=true
      owned=false
      owner=homebrew
    elif word_in_list "$name" "$FORMULA_SKIP"; then
      preexisting=true
      owned=false
      owner=external
      before=external
      [ -n "$after" ] || after=external
    elif [ -n "$after" ]; then
      preexisting=false
      owned=true
      owner=vibe-mac
    else
      continue
    fi
    manifest_record_package \
      formulae "$name" "$preexisting" "$owned" "$owner" "$before" "$after"
  done

  names="$(casks)"
  if [ "${EXTRAS:-0}" = "1" ]; then
    names="$names
$(extra_casks)"
  fi
  for name in $names; do
    history_status=0
    manifest_package_recorded casks "$name" || history_status="$?"
    case "$history_status" in
      0) continue ;;
      1) ;;
      *) return 2 ;;
    esac
    before="$(snapshot_version "$before_cask" "$name")"
    after="$(snapshot_version "$after_cask" "$name")"
    if [ -n "$before" ]; then
      preexisting=true
      owned=false
      owner=homebrew
    elif word_in_list "$name" "$CASK_SKIP"; then
      preexisting=true
      owned=false
      owner=external
      before=external
      [ -n "$after" ] || after=external
    elif [ -n "$after" ]; then
      preexisting=false
      owned=true
      owner=vibe-mac
    else
      continue
    fi
    manifest_record_package \
      casks "$name" "$preexisting" "$owned" "$owner" "$before" "$after"
  done
}

dependency_delta_rows_from_json() {
  local json body objects object prefix before_marker after_marker suffix
  local rest name old new canonical
  json="$1"
  [ "$json" != "[]" ] || return 0
  case "$json" in \[*\]) ;; *) return 2 ;; esac
  body="${json#\[}"
  body="${body%\]}"
  [ -n "$body" ] || return 2
  objects="$(printf '%s\n' "$body" | /usr/bin/sed 's/},{"name":"/}\
{"name":"/g')" || return 2
  prefix='{"name":"'
  before_marker='","before":"'
  after_marker='","after":"'
  suffix='"}'
  while IFS= read -r object; do
    rest="${object#"$prefix"}"
    [ "$rest" != "$object" ] || return 2
    name="${rest%%"$before_marker"*}"
    rest="${rest#"$name$before_marker"}"
    old="${rest%%"$after_marker"*}"
    rest="${rest#"$old$after_marker"}"
    new="${rest%"$suffix"}"
    canonical="$prefix$name$before_marker$old$after_marker$new$suffix"
    [ "$object" = "$canonical" ] || return 2
    case "$name" in ""|*[!A-Za-z0-9@._+-]*) return 2 ;; esac
    if ! printf '%s' "$old$new" |
      LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9@._+,: -]*$'; then
      return 2
    fi
    printf '%s|%s|%s\n' "$name" "$old" "$new"
  done <<EOF
$objects
EOF
}

merge_dependency_delta_json() {
  local existing current existing_body current_body
  existing="$1"
  current="$2"
  dependency_delta_rows_from_json "$existing" >/dev/null || return 2
  dependency_delta_rows_from_json "$current" >/dev/null || return 2
  if [ "$current" = "[]" ]; then
    printf '%s\n' "$existing"
    return 0
  fi
  if [ "$existing" = "[]" ]; then
    printf '%s\n' "$current"
    return 0
  fi
  existing_body="${existing#\[}"
  existing_body="${existing_body%\]}"
  current_body="${current#\[}"
  current_body="${current_body%\]}"
  printf '[%s,%s]\n' "$existing_body" "$current_body"
}

is_direct_formula() {
  local wanted name
  wanted="$1"
  for name in $(formulae); do
    [ "$name" = "$wanted" ] && return 0
  done
  return 1
}

record_dependency_delta() {
  local before after delta_file name old new delta_json separator
  local existing_delta merged_delta old_label new_label
  before="$1"
  after="$2"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  delta_file="$BREW_TEMP_DIR/formula-delta.txt"
  /usr/bin/awk '
    NR == FNR {
      before[$1] = $0
      names[$1] = 1
      next
    }
    {
      after[$1] = $0
      names[$1] = 1
    }
    END {
      for (name in names) {
        if (before[name] != after[name]) {
          print name "|" before[name] "|" after[name]
        }
      }
    }
  ' "$before" "$after" | LC_ALL=C /usr/bin/sort >"$delta_file"

  delta_json='['
  separator=
  while IFS='|' read -r name old new; do
    [ -n "$name" ] || continue
    if is_direct_formula "$name"; then
      continue
    fi
    if ! printf '%s' "$name$old$new" |
      LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9@._+,: -]*$'; then
      ui_fail "Homebrew delta содержит неожиданные символы."
      return 2
    fi
    delta_json="$delta_json$separator{\"name\":\"$name\",\"before\":\"$old\",\"after\":\"$new\"}"
    separator=,
    old_label="$old"
    new_label="$new"
    [ -n "$old_label" ] || old_label="не был установлен"
    [ -n "$new_label" ] || new_label="больше не установлен"
    ui_warn "Homebrew изменил служебный компонент: $name."
    printf '  Было: %s\n  Стало: %s\n' "$old_label" "$new_label"
  done <"$delta_file"
  delta_json="$delta_json]"
  existing_delta="$(plutil_run \
    -extract packages.dependency_delta json -o - -- \
    "$VIBE_MAC_MANIFEST_FILE")" || return 2
  merged_delta="$(merge_dependency_delta_json \
    "$existing_delta" "$delta_json")" || return 2
  manifest_record_dependency_delta "$merged_delta"
}

run_bundle_file() {
  local file
  file="$1"
  HOMEBREW_NO_AUTO_UPDATE=1 \
  HOMEBREW_NO_INSTALL_UPGRADE=1 \
  HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_BUNDLE_NO_UPGRADE=1 \
  HOMEBREW_BUNDLE_BREW_SKIP="$FORMULA_SKIP" \
  HOMEBREW_BUNDLE_CASK_SKIP="$CASK_SKIP" \
    brew_run bundle install --file="$file" --no-upgrade
}

apply_bundle() {
  local before_formula after_formula before_cask after_cask status
  status=0
  required_homebrew_executable brew >/dev/null || status="$?"
  if [ "$status" -ne 0 ]; then
    ui_fail "Homebrew не найден; сначала нужен шаг 20-homebrew."
    return "$status"
  fi

  build_skip_lists
  BREW_TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vibe-mac.brew.XXXXXX")"
  /bin/chmod 0700 "$BREW_TEMP_DIR"
  before_formula="$BREW_TEMP_DIR/formula-before.txt"
  after_formula="$BREW_TEMP_DIR/formula-after.txt"
  before_cask="$BREW_TEMP_DIR/cask-before.txt"
  after_cask="$BREW_TEMP_DIR/cask-after.txt"

  brew_run list --formula --versions >"$before_formula"
  brew_run list --cask --versions >"$before_cask"

  status=0
  bundle_ready || status="$?"
  if [ "$status" -eq 0 ]; then
    /bin/cp "$before_formula" "$after_formula"
    /bin/cp "$before_cask" "$after_cask"
    record_packages \
      "$before_formula" "$after_formula" "$before_cask" "$after_cask"
    record_dependency_delta "$before_formula" "$after_formula"
    cleanup_brew_temp
    return 0
  fi
  [ "$status" -eq 1 ] || return "$status"

  run_bundle_file "$VIBE_MAC_ROOT/Brewfile"
  if [ "${EXTRAS:-0}" = "1" ]; then
    run_bundle_file "$VIBE_MAC_ROOT/Brewfile.extras"
  fi

  brew_run list --formula --versions >"$after_formula"
  brew_run list --cask --versions >"$after_cask"
  assert_direct_versions_unchanged "$before_formula" "$after_formula"
  assert_direct_cask_versions_unchanged "$before_cask" "$after_cask"
  record_packages "$before_formula" "$after_formula" "$before_cask" "$after_cask"
  record_dependency_delta "$before_formula" "$after_formula"

  if ! /usr/bin/cmp -s "$before_formula" "$after_formula"; then
    ui_warn "Homebrew formula snapshot изменился; итог будет записан в manifest."
  fi
  if ! /usr/bin/cmp -s "$before_cask" "$after_cask"; then
    ui_info "Установлены новые cask из утверждённого списка."
  fi

  cleanup_brew_temp
  bundle_ready
}

trap cleanup_brew_temp EXIT
trap 'exit 130' INT TERM HUP

case "${1:-}" in
  plan)
    ui_info "Установлю утверждённый набор программ и отдельно покажу изменения их служебных компонентов."
    if [ "${EXTRAS:-0}" = "1" ]; then
      ui_info "Добавлю только Zed, Raycast и Visual Studio Code."
    fi
    ;;
  detect|verify)
    bundle_ready
    ;;
  verify-receipts)
    VIBE_MAC_VERIFY_RECEIPTS=1
    bundle_receipts_ready
    ;;
  apply)
    apply_bundle
    ;;
  *)
    ui_fail "30-brew-bundle: неизвестное действие."
    exit 2
    ;;
esac
