#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(/bin/realpath "$0" 2>/dev/null)" || {
  /usr/bin/printf '%s\n' 'Ошибка: verify.sh path нельзя канонизировать.' >&2
  exit 2
}
case "$SCRIPT_PATH" in
  /*/*) SCRIPT_DIR="${SCRIPT_PATH%/*}" ;;
  *)
    /usr/bin/printf '%s\n' 'Ошибка: verify.sh path небезопасен.' >&2
    exit 2
    ;;
esac
VIBE_MAC_ROOT="$SCRIPT_DIR"
export VIBE_MAC_ROOT

# `git archive` substitutes this marker before release packaging. Keep this
# guard before any test-only runtime path is accepted.
# shellcheck disable=SC2016
VIBE_MAC_VERIFY_BUILD_COMMIT='$Format:%H$'
# shellcheck disable=SC2016
case "$VIBE_MAC_VERIFY_BUILD_COMMIT" in
  *'$Format:'*) ;;
  *)
    if [ "${#VIBE_MAC_VERIFY_BUILD_COMMIT}" -ne 40 ] ||
      ! printf '%s\n' "$VIBE_MAC_VERIFY_BUILD_COMMIT" |
      LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{40}$'; then
      printf '%s\n' 'Ошибка: неизвестный build marker vibe-mac.' >&2
      exit 2
    fi
    VIBE_MAC_TEST_MODE=0
    export VIBE_MAC_TEST_MODE
    ;;
esac
readonly VIBE_MAC_VERIFY_BUILD_COMMIT

if [ "${VIBE_MAC_TEST_MODE:-0}" = 1 ]; then
  VIBE_MAC_RUNTIME_ROOT="${VIBE_MAC_RUNTIME_ROOT:-${HOME:?HOME не задан}/.vibe-mac}"
else
  VIBE_MAC_RUNTIME_ROOT="${HOME:?HOME не задан}/.vibe-mac"
fi
export VIBE_MAC_RUNTIME_ROOT

verify_integrity_fail() {
  printf 'Ошибка: установленный bundle vibe-mac отсутствует или повреждён: %s\n' \
    "$1" >&2
  printf '%s\n' \
    'Открой README и повтори versioned bootstrap-команду для нужной версии.' \
    >&2
  exit 2
}

verify_file_mode() {
  if /usr/bin/stat -f '%Lp' "$1" >/dev/null 2>&1; then
    /usr/bin/stat -f '%Lp' "$1"
  else
    /usr/bin/stat -c '%a' "$1"
  fi
}

verify_sha256_stdin() {
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

verify_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_release_tree_sha256() {
  local root absolute path
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  /usr/bin/find "$root" -mindepth 1 -print0 |
      while IFS= read -r -d '' absolute; do
        case "$absolute" in
          "$root"/*) path=".${absolute#"$root"}" ;;
          *) exit 2 ;;
        esac
        case "$path" in *[[:cntrl:]]*) exit 2 ;; esac
        case "$path" in ./*) ;; *) exit 2 ;; esac
        case "$path" in
          *\\*|*"/../"*|*"/./"*|*"//"*) exit 2 ;;
        esac
        if [ -L "$absolute" ]; then
          exit 2
        elif [ -f "$absolute" ] || [ -d "$absolute" ]; then
          :
        else
          exit 2
        fi
        case "$path" in
          ./.bundle-sha256|./.bundle-tree-sha256) continue ;;
        esac
        printf '%s\n' "$path"
      done | LC_ALL=C /usr/bin/sort |
      while IFS= read -r path; do
        absolute="$root/${path#./}"
        if [ -L "$absolute" ]; then
          exit 2
        elif [ -f "$absolute" ]; then
          printf 'F\t%s\t%s\t%s\n' \
            "$(verify_file_mode "$absolute")" \
            "$(verify_sha256_file "$absolute")" \
            "$path"
        elif [ -d "$absolute" ]; then
          printf 'D\t%s\t-\t%s\n' \
            "$(verify_file_mode "$absolute")" "$path"
        else
          exit 2
        fi
      done |
      verify_sha256_stdin
}

verify_sha_marker() {
  local marker value
  marker="$1"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value="$(/bin/cat "$marker")" || return 1
  [ "${#value}" -eq 64 ] || return 1
  case "$value" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$value"
}

verify_installed_bundle() {
  local current target version releases release release_physical
  local archive_sha expected_tree actual_tree
  current="$VIBE_MAC_RUNTIME_ROOT/current"
  releases="$VIBE_MAC_RUNTIME_ROOT/releases"

  [ -d "$HOME" ] && [ ! -L "$HOME" ] ||
    verify_integrity_fail 'HOME отсутствует или является symlink.'
  [ -d "$VIBE_MAC_RUNTIME_ROOT" ] && [ ! -L "$VIBE_MAC_RUNTIME_ROOT" ] ||
    verify_integrity_fail 'runtime root небезопасен.'
  [ -d "$releases" ] && [ ! -L "$releases" ] ||
    verify_integrity_fail 'каталог releases небезопасен.'
  [ -L "$current" ] ||
    verify_integrity_fail 'current должен быть symlink.'
  target="$(/usr/bin/readlink "$current")" ||
    verify_integrity_fail 'current не читается.'
  case "$target" in
    releases/[A-Za-z0-9]*)
      version="${target#releases/}"
      case "$version" in
        *[!A-Za-z0-9._-]*|*..*)
          verify_integrity_fail 'current содержит небезопасную версию.'
          ;;
      esac
      ;;
    *)
      verify_integrity_fail 'current выходит за releases/<version>.'
      ;;
  esac
  [ "$target" = "releases/$version" ] ||
    verify_integrity_fail 'current содержит extra path.'

  release="$VIBE_MAC_RUNTIME_ROOT/$target"
  [ -d "$release" ] && [ ! -L "$release" ] ||
    verify_integrity_fail 'release отсутствует или является symlink.'
  release_physical="$(/bin/realpath "$release" 2>/dev/null)" ||
    verify_integrity_fail 'release нельзя канонизировать.'
  [ "$SCRIPT_DIR" = "$release_physical" ] ||
    verify_integrity_fail 'verify запущен не из активного release.'
  [ -f "$release/install.sh" ] && [ ! -L "$release/install.sh" ] ||
    verify_integrity_fail 'install.sh отсутствует или не является regular file.'

  archive_sha="$(verify_sha_marker "$release/.bundle-sha256")" ||
    verify_integrity_fail '.bundle-sha256 отсутствует или malformed.'
  [ -n "$archive_sha" ] ||
    verify_integrity_fail '.bundle-sha256 пуст.'
  expected_tree="$(verify_sha_marker "$release/.bundle-tree-sha256")" ||
    verify_integrity_fail '.bundle-tree-sha256 отсутствует или malformed.'
  actual_tree="$(verify_release_tree_sha256 "$release")" ||
    verify_integrity_fail 'release tree нельзя безопасно проверить.'
  [ "$actual_tree" = "$expected_tree" ] ||
    verify_integrity_fail 'release tree fingerprint не совпал.'
}

verify_installed_bundle

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

verify_manifest_integrity_fail() {
  printf '%s\n' \
    'Ошибка: установленный manifest.json отсутствует или повреждён.' >&2
  printf '%s\n' \
    'Открой README и повтори versioned bootstrap-команду для нужной версии.' \
    >&2
  exit 2
}

verify_manifest_owned_value() {
  json_extract_typed "$VIBE_MAC_MANIFEST_FILE" "$1" bool
}

verify_manifest_typed_value() {
  json_extract_typed "$VIBE_MAC_MANIFEST_FILE" "$1" "$2" 2>/dev/null
}

verify_installed_manifest() {
  local schema installer_version install_id key field
  local release_owned version path_kind path archive_sha tree_sha release
  local release_physical actual_current current_path_kind current_path
  local current_target current_owned archive_marker tree_marker actual_tree
  local id expected_path launcher_path_kind launcher_path launcher_owned
  local expected_sha target actual_sha starship_owned omz_owned omz_tree_sha
  validate_home_dir_path "${VIBE_MAC_MANIFEST_FILE%/*}" || return 2
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] &&
    [ ! -L "$VIBE_MAC_MANIFEST_FILE" ] || return 2
  json_lint "$VIBE_MAC_MANIFEST_FILE" || return 2
  schema="$(verify_manifest_typed_value schema_version integer)" || return 2
  [ "$schema" = "$MANIFEST_SCHEMA_VERSION" ] || return 2
  installer_version="$(verify_manifest_typed_value \
    installer_version string)" || return 2
  case "$installer_version" in
    ""|*..*|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  [ "$installer_version" = "$VIBE_MAC_VERSION" ] || return 2
  install_id="$(verify_manifest_typed_value install_id string)" || return 2
  validate_logical_id "$install_id" || return 2

  for key in \
    releases releases.current releases.previous current_link launchers \
    launchers.verify launchers.doctor launchers.uninstall; do
    verify_manifest_typed_value "$key" dictionary >/dev/null || return 2
  done
  for key in releases.current releases.previous; do
    for field in version path_kind path archive_sha256 tree_sha256; do
      verify_manifest_typed_value \
        "$key.$field" string >/dev/null || return 2
    done
    verify_manifest_typed_value "$key.owned" bool >/dev/null || return 2
  done
  for field in path_kind path target; do
    verify_manifest_typed_value \
      "current_link.$field" string >/dev/null || return 2
  done
  verify_manifest_typed_value current_link.owned bool >/dev/null || return 2
  for id in verify doctor uninstall; do
    for field in path_kind path sha256; do
      verify_manifest_typed_value \
        "launchers.$id.$field" string >/dev/null || return 2
    done
    verify_manifest_typed_value "launchers.$id.owned" bool >/dev/null ||
      return 2
  done

  release_owned="$(verify_manifest_typed_value \
    releases.current.owned bool)" || return 2
  [ "$release_owned" = true ] || return 2
  version="$(verify_manifest_typed_value \
    releases.current.version string)" || return 2
  case "$version" in
    [A-Za-z0-9]*)
      case "$version" in *[!A-Za-z0-9._-]*|*..*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  path_kind="$(verify_manifest_typed_value \
    releases.current.path_kind string)" || return 2
  path="$(verify_manifest_typed_value releases.current.path string)" ||
    return 2
  archive_sha="$(verify_manifest_typed_value \
    releases.current.archive_sha256 string)" || return 2
  tree_sha="$(verify_manifest_typed_value \
    releases.current.tree_sha256 string)" || return 2
  [ "$path_kind" = runtime_relative ] || return 2
  [ "$path" = "releases/$version" ] || return 2
  validate_sha256_or_empty "$archive_sha" && [ -n "$archive_sha" ] ||
    return 2
  validate_sha256_or_empty "$tree_sha" && [ -n "$tree_sha" ] || return 2

  release="$VIBE_MAC_RUNTIME_ROOT/$path"
  validate_home_dir_path "$release" || return 2
  [ -d "$release" ] && [ ! -L "$release" ] || return 2
  release_physical="$(cd "$release" && pwd -P)" || return 2
  [ "$release_physical" = "$SCRIPT_DIR" ] || return 2
  [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ] || return 2
  actual_current="$(/usr/bin/readlink "$VIBE_MAC_RUNTIME_ROOT/current")" ||
    return 2
  [ "$actual_current" = "$path" ] || return 2

  current_path_kind="$(verify_manifest_typed_value \
    current_link.path_kind string)" || return 2
  current_path="$(verify_manifest_typed_value current_link.path string)" ||
    return 2
  current_target="$(verify_manifest_typed_value \
    current_link.target string)" || return 2
  current_owned="$(verify_manifest_typed_value current_link.owned bool)" ||
    return 2
  [ "$current_path_kind" = runtime_relative ] || return 2
  [ "$current_path" = current ] || return 2
  [ "$current_target" = "$path" ] || return 2
  [ "$current_owned" = true ] || return 2

  archive_marker="$(verify_sha_marker "$release/.bundle-sha256")" ||
    return 2
  tree_marker="$(verify_sha_marker "$release/.bundle-tree-sha256")" ||
    return 2
  [ "$archive_marker" = "$archive_sha" ] || return 2
  [ "$tree_marker" = "$tree_sha" ] || return 2
  actual_tree="$(verify_release_tree_sha256 "$release")" || return 2
  [ "$actual_tree" = "$tree_sha" ] || return 2

  validate_home_dir_path "$VIBE_MAC_RUNTIME_ROOT/bin" || return 2
  for id in verify doctor uninstall; do
    expected_path="bin/vibe-mac-$id"
    launcher_path_kind="$(verify_manifest_typed_value \
      "launchers.$id.path_kind" string)" || return 2
    launcher_path="$(verify_manifest_typed_value \
      "launchers.$id.path" string)" || return 2
    launcher_owned="$(verify_manifest_typed_value \
      "launchers.$id.owned" bool)" || return 2
    expected_sha="$(verify_manifest_typed_value \
      "launchers.$id.sha256" string)" || return 2
    [ "$launcher_path_kind" = runtime_relative ] || return 2
    [ "$launcher_path" = "$expected_path" ] || return 2
    [ "$launcher_owned" = true ] || return 2
    validate_sha256_or_empty "$expected_sha" && [ -n "$expected_sha" ] ||
      return 2
    target="$VIBE_MAC_RUNTIME_ROOT/$launcher_path"
    [ -f "$target" ] && [ ! -L "$target" ] && [ -x "$target" ] ||
      return 2
    actual_sha="$(verify_sha256_file "$target")" || return 2
    [ "$actual_sha" = "$expected_sha" ] || return 2
  done

  starship_owned="$(verify_manifest_owned_value files.starship.owned)" ||
    return 2
  omz_owned="$(verify_manifest_owned_value components.oh_my_zsh.owned)" ||
    return 2
  case "$starship_owned:$omz_owned" in
    true:true|true:false|false:true|false:false) ;;
    *) return 2 ;;
  esac
  if [ "$omz_owned" = true ]; then
    omz_tree_sha="$(verify_manifest_typed_value \
      components.oh_my_zsh.tree_sha256 string)" || return 2
    validate_sha256_or_empty "$omz_tree_sha" && [ -n "$omz_tree_sha" ] ||
      return 2
  fi
}

verify_installed_manifest || verify_manifest_integrity_fail

VERIFY_HOMEBREW_BIN_DIR=

verify_expected_homebrew_prefix() {
  if is_test_mode &&
    [ -n "${VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX:-}" ]; then
    case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
      /*)
        case "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" in
          *$'\n'*|*$'\r'*|*$'\t'*|*"'"*) return 2 ;;
        esac
        printf '%s\n' "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX"
        return 0
        ;;
      *) return 2 ;;
    esac
  fi
  expected_homebrew_prefix
}

configure_verify_homebrew_path() {
  local prefix bin
  prefix="$(verify_expected_homebrew_prefix)" || return 2
  bin="$prefix/bin"
  [ -d "$prefix" ] && [ ! -L "$prefix" ] ||
    return 1
  [ -d "$bin" ] && [ ! -L "$bin" ] ||
    return 1
  VERIFY_HOMEBREW_BIN_DIR="$bin"
  PATH="$bin:$prefix/sbin:$PATH"
  export PATH
}

verify_homebrew_executable() {
  local name prefix
  name="$1"
  case "$name" in
    brew|git|gh|starship|rg|fd|fzf|bat|eza|jq|tree|zoxide|mise|uv|claude|codex|cursor-agent)
      ;;
    *) return 2 ;;
  esac
  [ -n "$VERIFY_HOMEBREW_BIN_DIR" ] ||
    configure_verify_homebrew_path || return "$?"
  prefix="$(verify_expected_homebrew_prefix)" || return 2
  [ "$VERIFY_HOMEBREW_BIN_DIR" = "$prefix/bin" ] || return 2
  homebrew_executable_in_prefix "$prefix" "$name"
}

READY_COUNT=0
FAILED_COUNT=0
FATAL_ERROR=0
REPAIR_COMMAND='открой README и повтори versioned bootstrap-команду для нужной версии'

usage() {
  printf '%s\n' "Запуск: /bin/bash ./verify.sh"
}

run_step_verify() {
  DRY_RUN=1 /bin/bash "$VIBE_MAC_ROOT/steps/$1.sh" verify
}

run_brew_receipts_verify() {
  if is_test_mode; then
    VIBE_MAC_TEST_VERIFY_FIXTURE_HOME="$HOME" \
      VIBE_MAC_FULL_VERIFY=1 DRY_RUN=1 \
      /bin/bash "$VIBE_MAC_ROOT/steps/30-brew-bundle.sh" verify-receipts
    return
  fi
  VIBE_MAC_FULL_VERIFY=1 DRY_RUN=1 \
    /bin/bash "$VIBE_MAC_ROOT/steps/30-brew-bundle.sh" verify-receipts
}

sanitize_probe_detail() {
  printf '%s\n' "$1" | LC_ALL=C /usr/bin/awk '
    {
      line = $0
      gsub(/[^ -~]/, "", line)
      if (line ~ /[^ ]/) {
        print substr(line, 1, 240)
        exit
      }
    }
  '
}

verify_run_clean_command() {
  local command_bin command_name prefix clean_path probe_home probe_tmp
  local run_user resolved safe_cwd
  local trusted_config data_dir cache_dir state_dir status
  local -a clean_env
  [ "$#" -gt 0 ] || return 2
  command_bin="$1"
  shift
  command_name="${command_bin##*/}"
  prefix="$(verify_expected_homebrew_prefix)" || return 2
  resolved="$(verify_homebrew_executable "$command_name")" || return "$?"
  [ "$command_bin" = "$resolved" ] || return 2
  clean_path="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  run_user="$(/usr/bin/id -un)" || return 2
  [ -d /var/empty ] && [ ! -L /var/empty ] || return 2
  safe_cwd="$(cd /var/empty && pwd -P)" || return 2
  probe_home=/var/empty
  probe_tmp=/var/empty
  if [ "$command_name" = mise ]; then
    probe_home="$HOME"
    probe_tmp=/tmp
  fi
  clean_env=(
    /usr/bin/env -i
    "HOME=$probe_home"
    "USER=$run_user"
    "LOGNAME=$run_user"
    SHELL=/bin/zsh
    "PATH=$clean_path"
    "TMPDIR=$probe_tmp"
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
  )
  if is_test_mode; then
    clean_env+=(
      "VIBE_MAC_TEST_VERIFY_CLEAN_PROBE=${VIBE_MAC_TEST_VERIFY_CLEAN_PROBE:-0}"
      "VIBE_MAC_TEST_VERIFY_FIXTURE_HOME=$HOME"
      "VIBE_MAC_EVENT_LOG=${VIBE_MAC_EVENT_LOG:-}"
    )
  fi

  if [ "$command_name" = mise ]; then
    trusted_config="$VIBE_MAC_ROOT/config"
    data_dir="$HOME/.local/share/mise"
    cache_dir="$HOME/.cache/mise"
    state_dir="$HOME/.local/state/mise"
    [ -d "$trusted_config" ] && [ ! -L "$trusted_config" ] || return 2
    validate_home_dir_path "$data_dir" || return 2
    validate_home_dir_path "$cache_dir" || return 2
    validate_home_dir_path "$state_dir" || return 2
    clean_env+=(
      MISE_YES=1
      MISE_AUTO_INSTALL=0
      MISE_EXEC_AUTO_INSTALL=0
      MISE_OFFLINE=1
      "MISE_CONFIG_DIR=$trusted_config"
      MISE_GLOBAL_CONFIG_FILE=/dev/null
      MISE_SYSTEM_CONFIG_FILE=/dev/null
      "MISE_DATA_DIR=$data_dir"
      "MISE_CACHE_DIR=$cache_dir"
      "MISE_STATE_DIR=$state_dir"
      MISE_TMP_DIR=/tmp
    )
    status=0
    (
      cd "$safe_cwd"
      "${clean_env[@]}" "$command_bin" -C "$trusted_config" "$@"
    ) || status="$?"
    [ "$status" -eq 0 ] && return 0
    return 1
  fi

  status=0
  (
    cd "$safe_cwd"
    "${clean_env[@]}" "$command_bin" "$@"
  ) || status="$?"
  [ "$status" -eq 0 ] && return 0
  return 1
}

safe_command_output() {
  local output safe status
  if output="$(verify_run_clean_command "$@" 2>&1)"; then
    :
  else
    status="$?"
    return "$status"
  fi
  safe="$(sanitize_probe_detail "$output")" || return 1
  [ -n "$safe" ] || return 1
  printf '%s\n' "$safe"
}

probe_clt() {
  run_step_verify 10-xcode-clt
}

probe_homebrew() {
  local brew_bin version
  run_step_verify 20-homebrew || return
  run_brew_receipts_verify || return
  brew_bin="$(verify_homebrew_executable brew)" || return "$?"
  version="$(safe_command_output "$brew_bin" --version)" || return "$?"
  printf 'Homebrew: %s\n' "$version"
}

probe_git_gh() {
  local gh_bin gh_version git_bin git_version
  run_step_verify 70-git-github || return
  git_bin="$(verify_homebrew_executable git)" || return "$?"
  gh_bin="$(verify_homebrew_executable gh)" || return "$?"
  git_version="$(safe_command_output "$git_bin" --version)" || return "$?"
  gh_version="$(safe_command_output "$gh_bin" --version)" || return "$?"
  printf 'Git: %s; gh: %s\n' "$git_version" "$gh_version"
}

probe_ghostty() {
  local app
  if is_test_mode && [ -n "${VIBE_MAC_TEST_GHOSTTY_APP:-}" ]; then
    app="$VIBE_MAC_TEST_GHOSTTY_APP"
  else
    app=/Applications/Ghostty.app
  fi
  macos_app_bundle_ready "$app"
}

verify_zprofile_managed_content() {
  local prefix
  prefix="$(verify_expected_homebrew_prefix)" || return 2
  shell_zprofile_managed_content_for_prefix "$prefix"
}

verify_zshrc_activation_content() {
  local prefix
  prefix="$(verify_expected_homebrew_prefix)" || return 2
  shell_zshrc_activation_content_for_prefix "$prefix"
}

verify_zshrc_managed_content() {
  local prefix
  prefix="$(verify_expected_homebrew_prefix)" || return 2
  shell_zshrc_managed_content_for_prefix "$prefix"
}

verify_managed_block_sha() {
  local target block_id begin end
  target="$1"
  block_id="$2"
  begin="# >>> vibe-mac managed:$block_id >>>"
  end="# <<< vibe-mac managed:$block_id <<<"
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
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
  ' "$target" | verify_sha256_stdin
}

verify_shell_blocks_ready() {
  local zprofile_content zshrc_content zshrc_activation ghostty_content actual
  local zprofile_sha zshrc_sha zshrc_activation_sha ghostty_sha
  zprofile_content="$(verify_zprofile_managed_content)" || return 2
  zshrc_content="$(verify_zshrc_managed_content)" || return 2
  zshrc_activation="$(verify_zshrc_activation_content)" || return 2
  zprofile_sha="$(sha256_text "$zprofile_content")"
  zshrc_sha="$(sha256_text "$zshrc_content")"
  zshrc_activation_sha="$(sha256_text "$zshrc_activation")"
  ghostty_content="$(/bin/cat "$VIBE_MAC_ROOT/config/ghostty.config")" ||
    return 2
  ghostty_sha="$(sha256_text "$ghostty_content")"

  actual="$(verify_managed_block_sha "$HOME/.zprofile" zprofile)" ||
    return 1
  [ "$actual" = "$zprofile_sha" ] || return 1
  actual="$(verify_managed_block_sha "$HOME/.zshrc" zshrc)" || return 1
  if [ "$actual" = "$zshrc_sha" ]; then
    :
  elif [ "$actual" = "$zshrc_activation_sha" ]; then
    zshrc_has_external_omz_source "$HOME/.zshrc" zshrc || return 1
  else
    return 1
  fi
  actual="$(verify_managed_block_sha \
    "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
    ghostty)" || return 1
  [ "$actual" = "$ghostty_sha" ]
}

verify_owned_aliases_ready() {
  local target owned
  target="$HOME/.config/vibe-mac/aliases.zsh"
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  owned="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" files.aliases.owned 2>/dev/null || true)"
  case "$owned" in
    ""|false) return 0 ;;
    true) ;;
    *) return 1 ;;
  esac
  /usr/bin/cmp -s "$VIBE_MAC_ROOT/config/aliases.zsh" "$target"
}

verify_owned_starship_ready() {
  local target owned status
  target="$HOME/.config/starship.toml"
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  owned="$(verify_manifest_owned_value files.starship.owned)" || return 2
  case "$owned" in
    false) return 0 ;;
    true) ;;
    *) return 2 ;;
  esac
  /usr/bin/cmp -s "$VIBE_MAC_ROOT/config/starship.toml" "$target" &&
    return 0
  status="$?"
  [ "$status" -eq 1 ] && return 1
  return 2
}

verify_owned_omz_tree_ready() {
  local owned expected actual
  owned="$(verify_manifest_owned_value components.oh_my_zsh.owned)" ||
    return 2
  case "$owned" in
    false) return 0 ;;
    true) ;;
    *) return 2 ;;
  esac
  expected="$(plutil_run -extract components.oh_my_zsh.tree_sha256 \
    raw -expect string -- "$VIBE_MAC_MANIFEST_FILE")" || return 2
  validate_sha256_or_empty "$expected" && [ -n "$expected" ] || return 2
  actual="$(tree_sha256 "$HOME/.oh-my-zsh")" || return 2
  [ "$actual" = "$expected" ]
}

probe_shell() {
  local font_dir zsh_bin starship_bin starship_version
  run_step_verify 40-shell || return
  zsh_bin=/bin/zsh
  if is_test_mode && [ -n "${VIBE_MAC_TEST_ZSH_BIN:-}" ]; then
    zsh_bin="$VIBE_MAC_TEST_ZSH_BIN"
  fi
  [ -f "$zsh_bin" ] && [ ! -L "$zsh_bin" ] && [ -x "$zsh_bin" ] ||
    return 1
  [ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] &&
    [ ! -L "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] || return 1
  starship_bin="$(verify_homebrew_executable starship)" || return "$?"
  starship_version="$(safe_command_output "$starship_bin" --version)" ||
    return "$?"
  verify_shell_blocks_ready || return "$?"
  verify_owned_aliases_ready || return "$?"
  verify_owned_starship_ready || return "$?"
  verify_owned_omz_tree_ready || return "$?"

  if is_test_mode && [ -n "${VIBE_MAC_TEST_FONT_DIR:-}" ]; then
    font_dir="$VIBE_MAC_TEST_FONT_DIR"
  else
    font_dir="$HOME/Library/Fonts"
  fi
  font_dir_has_jetbrains_mono_nerd_font "$font_dir" || return "$?"
  printf 'Starship: %s\n' "$starship_version"
}

probe_cli_set() {
  local command_name command_bin detail details
  details=
  for command_name in rg fd fzf bat eza jq tree zoxide; do
    command_bin="$(verify_homebrew_executable "$command_name")" || return "$?"
    detail="$(safe_command_output "$command_bin" --version)" || return "$?"
    details="${details:+$details; }$command_name=$detail"
  done
  printf 'CLI: %s\n' "$details"
}

probe_mise() {
  local detail mise_bin output version
  mise_bin="$(verify_homebrew_executable mise)" || return "$?"
  output="$(verify_run_clean_command "$mise_bin" --version 2>/dev/null)" ||
    return "$?"
  version="$(printf '%s\n' "$output" |
    /usr/bin/grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' |
    /usr/bin/head -n 1)"
  [ -n "$version" ] || return 1
  version_at_least "$version" "$MISE_MIN_TESTED_VERSION" || return 1
  verify_shell_blocks_ready || return "$?"
  detail="$(sanitize_probe_detail "$output")" || return 1
  [ -n "$detail" ] || return 1
  printf 'mise: %s\n' "$detail"
}

verify_mise_runtime_path() {
  local command data_root data_root_physical executable executable_physical
  local expected expected_physical item mise_bin name reported reported_physical
  local status version
  name="$1"
  version="$2"
  case "$name" in
    node) command=node ;;
    python) command=python ;;
    *) return 2 ;;
  esac
  case "$version" in
    ""|*..*|*[!0-9.]*) return 2 ;;
  esac
  item="$name@$version"
  data_root="$HOME/.local/share/mise/installs"
  expected="$data_root/$name/$version"
  validate_home_dir_path "$expected" || return 2
  mise_bin="$(verify_homebrew_executable mise)" || return "$?"
  if reported="$(verify_run_clean_command \
    "$mise_bin" where "$item" 2>/dev/null)"; then
    :
  else
    status="$?"
    [ "$status" -ne 2 ] || return 2
    if [ ! -e "$expected" ] && [ ! -L "$expected" ]; then
      return 1
    fi
    return 2
  fi
  case "$reported" in
    /*)
      case "$reported" in *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  [ -d "$data_root" ] && [ ! -L "$data_root" ] || return 2
  [ -d "$expected" ] && [ ! -L "$expected" ] || return 2
  [ -x /bin/realpath ] || return 2
  data_root_physical="$(/bin/realpath "$data_root" 2>/dev/null)" || return 2
  expected_physical="$(/bin/realpath "$expected" 2>/dev/null)" || return 2
  reported_physical="$(/bin/realpath "$reported" 2>/dev/null)" || return 2
  [ "$expected_physical" = "$data_root_physical/$name/$version" ] ||
    return 2
  [ "$reported_physical" = "$expected_physical" ] || return 2
  executable="$expected/bin/$command"
  [ -e "$executable" ] || [ -L "$executable" ] || return 2
  executable_physical="$(/bin/realpath "$executable" 2>/dev/null)" ||
    return 2
  case "$executable_physical" in
    "$expected_physical"/*) ;;
    *) return 2 ;;
  esac
  [ -f "$executable_physical" ] && [ ! -L "$executable_physical" ] &&
    [ -x "$executable_physical" ] || return 2
  printf '%s\n' "$expected_physical"
}

probe_node() {
  local mise_bin output runtime_path
  [ -d "$HOME/dev/hello-vibe" ] || return 1
  runtime_path="$(verify_mise_runtime_path node "$NODE_VERSION")" ||
    return "$?"
  [ -n "$runtime_path" ] || return 2
  mise_bin="$(verify_homebrew_executable mise)" || return "$?"
  output="$(verify_run_clean_command \
    "$mise_bin" exec "node@$NODE_VERSION" -- node --version 2>/dev/null)" ||
    return "$?"
  [ "$output" = "v$NODE_VERSION" ] || return 1
  printf 'Node.js: %s\n' "$output"
}

probe_python() {
  local mise_bin output runtime_path
  [ -d "$HOME/dev/hello-vibe" ] || return 1
  runtime_path="$(verify_mise_runtime_path python "$PYTHON_VERSION")" ||
    return "$?"
  [ -n "$runtime_path" ] || return 2
  mise_bin="$(verify_homebrew_executable mise)" || return "$?"
  output="$(verify_run_clean_command \
    "$mise_bin" exec "python@$PYTHON_VERSION" -- python --version 2>&1)" ||
    return "$?"
  [ "$output" = "Python $PYTHON_VERSION" ] || return 1
  printf 'Python: %s\n' "$output"
}

probe_uv() {
  local uv_bin output
  uv_bin="$(verify_homebrew_executable uv)" || return "$?"
  output="$(verify_run_clean_command "$uv_bin" --version 2>/dev/null)" ||
    return "$?"
  case "$output" in
    "uv "[0-9]*) printf 'uv: %s\n' "$output" ;;
    *) return 1 ;;
  esac
}

probe_ai() {
  local command_name command_bin cursor_app detail details
  run_step_verify 60-ai-agents || return
  if is_test_mode && [ -n "${VIBE_MAC_TEST_CURSOR_APP:-}" ]; then
    cursor_app="$VIBE_MAC_TEST_CURSOR_APP"
  else
    cursor_app=/Applications/Cursor.app
  fi
  macos_app_bundle_ready "$cursor_app" || return 1
  details=
  for command_name in claude codex cursor-agent; do
    command_bin="$(verify_homebrew_executable "$command_name")" || return "$?"
    detail="$(safe_command_output "$command_bin" --version)" || return "$?"
    details="${details:+$details; }$command_name=$detail"
  done
  printf 'AI CLI: %s\n' "$details"
}

probe_workspace() {
  run_step_verify 90-workspace
}

emit_probe() {
  local name result
  name="$1"
  result="$2"
  case "$result" in
    0)
      READY_COUNT=$((READY_COUNT + 1))
      ui_status "Уже стоит" "$name"
      ;;
    1)
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ui_status "Ошибка" "$name"
      printf '  Исправить: %s\n' "$REPAIR_COMMAND"
      ;;
    2)
      FATAL_ERROR=1
      ui_status "Ошибка" "$name: проверка не смогла выполниться"
      ;;
    *)
      FATAL_ERROR=1
      ui_status "Ошибка" "$name: неизвестный результат"
      ;;
  esac
}

call_probe() {
  local details function_name name status
  name="$1"
  function_name="$2"
  if details="$("$function_name" 2>/dev/null)"; then
    status=0
  else
    status="$?"
    case "$status" in
      1) ;;
      *) status=2 ;;
    esac
  fi
  emit_probe "$name" "$status"
  if [ "$status" -eq 0 ] && [ -n "$details" ]; then
    emit_probe_details "$details"
  fi
}

emit_probe_details() {
  local count details line safe
  details="$1"
  count=0
  while IFS= read -r line; do
    safe="$(sanitize_probe_detail "$line")" || continue
    [ -n "$safe" ] || continue
    printf '  %s\n' "$safe"
    count=$((count + 1))
    [ "$count" -lt 8 ] || break
  done <<<"$details"
}

run_test_probes() {
  local results value
  results="$VIBE_MAC_TEST_VERIFY_RESULTS"
  # Intentional word splitting: contract is exactly twelve 0/1 tokens.
  # shellcheck disable=SC2086
  set -- $results
  if [ "$#" -ne 12 ]; then
    ui_fail "Некорректные test probes: ожидалось 12 значений."
    return 2
  fi
  for value in "$@"; do
    case "$value" in 0|1) ;; *)
      ui_fail "Некорректные test probes: разрешены только 0/1."
      return 2
    esac
  done
  emit_probe "Xcode Command Line Tools" "$([ "$1" = 1 ] && printf 0 || printf 1)"
  emit_probe "Homebrew" "$([ "$2" = 1 ] && printf 0 || printf 1)"
  emit_probe "Git и GitHub CLI" "$([ "$3" = 1 ] && printf 0 || printf 1)"
  emit_probe "Ghostty" "$([ "$4" = 1 ] && printf 0 || printf 1)"
  emit_probe "zsh, Oh My Zsh, Starship и шрифт" "$([ "$5" = 1 ] && printf 0 || printf 1)"
  emit_probe "CLI-набор" "$([ "$6" = 1 ] && printf 0 || printf 1)"
  emit_probe "mise и shell activation" "$([ "$7" = 1 ] && printf 0 || printf 1)"
  emit_probe "Node.js" "$([ "$8" = 1 ] && printf 0 || printf 1)"
  emit_probe "Python" "$([ "$9" = 1 ] && printf 0 || printf 1)"
  emit_probe "uv" "$([ "${10}" = 1 ] && printf 0 || printf 1)"
  emit_probe "AI CLI и Cursor" "$([ "${11}" = 1 ] && printf 0 || printf 1)"
  emit_probe "Workspace и доктрина" "$([ "${12}" = 1 ] && printf 0 || printf 1)"
}

offline_auth_status() {
  local config_dir label login_command status_command
  label="$1"
  config_dir="$2"
  status_command="$3"
  login_command="$4"
  if ! validate_home_dir_path "$config_dir"; then
    FATAL_ERROR=1
    printf '• Вход %s: integrity-ошибка конфигурации\n' "$label"
    return
  fi
  printf '• Вход %s: не проверяется офлайн\n' "$label"
  printf '  Проверить: %s\n' "$status_command"
  printf '  Войти: %s\n' "$login_command"
}

run_real_probes() {
  configure_verify_homebrew_path >/dev/null 2>&1 || true
  call_probe "Xcode Command Line Tools" probe_clt
  call_probe "Homebrew" probe_homebrew
  call_probe "Git и GitHub CLI" probe_git_gh
  call_probe "Ghostty" probe_ghostty
  call_probe "zsh, Oh My Zsh, Starship и шрифт" probe_shell
  call_probe "CLI-набор" probe_cli_set
  call_probe "mise и shell activation" probe_mise
  call_probe "Node.js" probe_node
  call_probe "Python" probe_python
  call_probe "uv" probe_uv
  call_probe "AI CLI и Cursor" probe_ai
  call_probe "Workspace и доктрина" probe_workspace
}

case "${1:-}" in
  "")
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

if is_test_mode && [ -n "${VIBE_MAC_TEST_VERIFY_RESULTS:-}" ]; then
  run_test_probes || exit 2
else
  run_real_probes
fi

printf '\n%s из 12 готово.\n' "$READY_COUNT"
if auth_prefix="$(verify_expected_homebrew_prefix)"; then
  printf '\nСтатусы входов (не влияют на 12 технических критериев):\n'
  offline_auth_status GitHub "$HOME/.config/gh" \
    "$auth_prefix/bin/gh auth status --hostname github.com" \
    "$auth_prefix/bin/gh auth login --hostname github.com --web --git-protocol https"
  offline_auth_status Claude "$HOME/.claude" \
    "$auth_prefix/bin/claude auth status --text" \
    "$auth_prefix/bin/claude auth login"
  offline_auth_status Codex "$HOME/.codex" \
    "$auth_prefix/bin/codex login status" \
    "$auth_prefix/bin/codex login"
  offline_auth_status "Cursor Agent" "$HOME/.cursor" \
    "$auth_prefix/bin/cursor-agent status" \
    "$auth_prefix/bin/cursor-agent login"
  printf '• Вход Cursor Desktop: не проверяется офлайн\n'
  printf '%s\n' \
    '  Проверить и войти: /usr/bin/open /Applications/Cursor.app'
else
  printf '%s\n' '• Входы: integrity-ошибка trusted Homebrew prefix.'
  FATAL_ERROR=1
fi

if [ "$FATAL_ERROR" -ne 0 ]; then
  exit 2
fi
if [ "$FAILED_COUNT" -ne 0 ]; then
  exit 1
fi
