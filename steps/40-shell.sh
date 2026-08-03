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

OMZ_TEMP_DIR=

shell_expected_homebrew_prefix() {
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

zprofile_managed_content() {
  local prefix
  prefix="$(shell_expected_homebrew_prefix)" || return 2
  shell_zprofile_managed_content_for_prefix "$prefix"
}

zshrc_activation_content() {
  local prefix
  prefix="$(shell_expected_homebrew_prefix)" || return 2
  shell_zshrc_activation_content_for_prefix "$prefix"
}

zshrc_managed_content() {
  local prefix
  prefix="$(shell_expected_homebrew_prefix)" || return 2
  shell_zshrc_managed_content_for_prefix "$prefix"
}

omz_creation_proof_path() {
  validate_logical_id "${VIBE_MAC_INSTALL_ID:-}" || return 2
  printf '%s/%s/%s\n' \
    "$VIBE_MAC_BACKUP_ROOT" \
    "$VIBE_MAC_INSTALL_ID" \
    oh-my-zsh.created-tree-sha256
}

write_omz_creation_proof() {
  local backup_dir evidence proof temp tree existing
  proof="$(omz_creation_proof_path)" || return 2
  backup_dir="${proof%/*}"
  validate_home_dir_path "$backup_dir" || return 2
  [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 2
  evidence="$(backup_evidence_kind oh-my-zsh)" || return 2
  [ "$evidence" = absent ] || return 2

  tree="$(tree_sha256 "$HOME/.oh-my-zsh")" || return 2
  if [ -e "$proof" ] || [ -L "$proof" ]; then
    [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
    existing="$(/bin/cat "$proof")" || return 2
    validate_sha256_or_empty "$existing" && [ -n "$existing" ] || return 2
    [ "$existing" = "$tree" ] || return 2
    return 0
  fi

  temp="$(/usr/bin/mktemp "$backup_dir/.oh-my-zsh-proof.XXXXXX")"
  if ! printf '%s\n' "$tree" >"$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  if ! /bin/ln "$temp" "$proof"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/unlink "$temp"
}

omz_creation_proof_matches() {
  local backup_dir proof expected actual
  proof="$(omz_creation_proof_path)" || return 2
  backup_dir="${proof%/*}"
  validate_home_dir_path "$backup_dir" || return 2
  if [ ! -e "$proof" ] && [ ! -L "$proof" ]; then
    return 1
  fi
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
  expected="$(/bin/cat "$proof")" || return 2
  validate_sha256_or_empty "$expected" && [ -n "$expected" ] || return 2
  actual="$(tree_sha256 "$HOME/.oh-my-zsh")" || return 2
  [ "$actual" = "$expected" ]
}

shell_file_creation_proof_path() {
  local logical
  logical="$1"
  validate_logical_id "$logical" || return 2
  printf '%s/%s/%s.created-file-sha256\n' \
    "$VIBE_MAC_BACKUP_ROOT" \
    "${VIBE_MAC_INSTALL_ID:?install ID не задан}" \
    "$logical"
}

write_shell_file_creation_proof() {
  local logical target allow_replace proof backup_dir evidence sha existing temp
  logical="$1"
  target="$2"
  allow_replace="${3:-0}"
  case "$allow_replace" in 0|1) ;; *) return 2 ;; esac
  proof="$(shell_file_creation_proof_path "$logical")" || return 2
  backup_dir="${proof%/*}"
  validate_home_dir_path "$backup_dir" || return 2
  [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 2
  evidence="$(backup_evidence_kind "$logical")" || return 2
  [ "$evidence" = absent ] || return 2
  [ -f "$target" ] && [ ! -L "$target" ] || return 2
  sha="$(sha256_file "$target")" || return 2
  validate_sha256_or_empty "$sha" && [ -n "$sha" ] || return 2

  if [ -e "$proof" ] || [ -L "$proof" ]; then
    [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
    existing="$(/bin/cat "$proof")" || return 2
    validate_sha256_or_empty "$existing" && [ -n "$existing" ] || return 2
    if [ "$existing" = "$sha" ]; then
      return 0
    fi
    [ "$allow_replace" = 1 ] || return 2
  fi

  temp="$(/usr/bin/mktemp "$backup_dir/.$logical-proof.XXXXXX")"
  if ! printf '%s\n' "$sha" >"$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  if [ -e "$proof" ]; then
    /bin/mv -f "$temp" "$proof"
    return
  fi
  if ! /bin/ln "$temp" "$proof"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/unlink "$temp"
}

shell_file_creation_proof_matches() {
  local logical target applied_sha proof expected actual
  logical="$1"
  target="$2"
  applied_sha="$3"
  proof="$(shell_file_creation_proof_path "$logical")" || return 2
  if [ ! -e "$proof" ] && [ ! -L "$proof" ]; then
    return 1
  fi
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
  expected="$(/bin/cat "$proof")" || return 2
  validate_sha256_or_empty "$expected" && [ -n "$expected" ] || return 2
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  actual="$(sha256_file "$target")" || return 2
  [ "$expected" = "$actual" ] && [ "$actual" = "$applied_sha" ]
}

shell_managed_block_sha() {
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
  ' "$target" | sha256_stdin
}

shell_block_creation_proof_path() {
  local logical
  logical="$1"
  validate_logical_id "$logical" || return 2
  printf '%s/%s/%s.created-block-sha256\n' \
    "$VIBE_MAC_BACKUP_ROOT" \
    "${VIBE_MAC_INSTALL_ID:?install ID не задан}" \
    "$logical"
}

write_shell_block_creation_proof() {
  local logical target block_id applied_sha proof backup_dir
  local evidence actual existing temp
  logical="$1"
  target="$2"
  block_id="$3"
  applied_sha="$4"
  proof="$(shell_block_creation_proof_path "$logical")" || return 2
  backup_dir="${proof%/*}"
  validate_home_dir_path "$backup_dir" || return 2
  [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 2
  evidence="$(backup_evidence_kind "$logical")" || return 2
  case "$evidence" in file|absent) ;; *) return 2 ;; esac
  actual="$(shell_managed_block_sha "$target" "$block_id")" || return 2
  [ "$actual" = "$applied_sha" ] || return 2

  if [ -e "$proof" ] || [ -L "$proof" ]; then
    [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
    existing="$(/bin/cat "$proof")" || return 2
    validate_sha256_or_empty "$existing" && [ -n "$existing" ] || return 2
    if [ "$existing" = "$actual" ]; then
      return 0
    fi
  fi

  temp="$(/usr/bin/mktemp "$backup_dir/.$logical-block-proof.XXXXXX")"
  if ! printf '%s\n' "$actual" >"$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/chmod 0600 "$temp"
  if [ -e "$proof" ]; then
    /bin/mv -f "$temp" "$proof"
    return
  fi
  if ! /bin/ln "$temp" "$proof"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  /bin/unlink "$temp"
}

shell_block_creation_proof_matches() {
  local logical target block_id applied_sha proof expected actual
  logical="$1"
  target="$2"
  block_id="$3"
  applied_sha="$4"
  proof="$(shell_block_creation_proof_path "$logical")" || return 2
  if [ ! -e "$proof" ] && [ ! -L "$proof" ]; then
    return 1
  fi
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 2
  expected="$(/bin/cat "$proof")" || return 2
  validate_sha256_or_empty "$expected" && [ -n "$expected" ] || return 2
  actual="$(shell_managed_block_sha "$target" "$block_id")" || return 1
  [ "$expected" = "$actual" ] && [ "$actual" = "$applied_sha" ]
}

install_owned_shell_file_if_absent() {
  local source target logical parent temp id relative source_sha current_sha
  local entry_owned previous_sha entry_present allow_proof_replace
  source="$1"
  target="$2"
  logical="$3"
  validate_logical_id "$logical" || return 2
  home_relative_from_absolute "$target" >/dev/null || return 2
  parent="${target%/*}"
  validate_home_dir_path "$parent" || return 2
  [ -f "$source" ] && [ ! -L "$source" ] || return 2
  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    return 2
  fi

  case "$logical" in
    aliases-zsh) id=aliases ;;
    starship-toml) id=starship ;;
    *) return 2 ;;
  esac
  relative="$(home_relative_from_absolute "$target")" || return 2
  source_sha="$(sha256_file "$source")" || return 2
  entry_present=0
  entry_owned=false
  previous_sha=
  if [ -f "$VIBE_MAC_MANIFEST_FILE" ] &&
    json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned" \
      >/dev/null 2>&1; then
    entry_present=1
    manifest_validate_file_entry \
      "$id" "$relative" owned_file "" "$logical" || return 2
    entry_owned="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned")" || return 2
    previous_sha="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" "files.$id.applied_sha")" || return 2
  fi

  ensure_parent_dir "$target"
  backup_file_once "$target" "$logical" >/dev/null || return 2
  if [ -e "$target" ]; then
    current_sha="$(sha256_file "$target")" || return 2
    if [ "$current_sha" = "$source_sha" ]; then
      if [ "$entry_present" = 1 ] && [ "$entry_owned" = true ]; then
        write_shell_file_creation_proof "$logical" "$target" 1
      fi
      return 0
    fi
    if [ "$entry_present" != 1 ] || [ "$entry_owned" != true ]; then
      return 0
    fi
    if [ "$current_sha" != "$previous_sha" ]; then
      ui_fail "Owned shell file $id изменён пользователем; upgrade остановлен."
      return 2
    fi
  fi
  if is_test_mode &&
    [ "${VIBE_MAC_TEST_CRASH_AFTER_FILE_EVIDENCE:-}" = "$logical" ]; then
    return 93
  fi

  temp="$(/usr/bin/mktemp "$parent/.vibe-mac-file.XXXXXX")"
  if ! /bin/cp "$source" "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 1
  fi
  /bin/chmod 0600 "$temp"
  if ! /bin/mv -f "$temp" "$target"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 1
  fi
  allow_proof_replace=0
  if [ "$entry_present" = 1 ] && [ "$entry_owned" = true ]; then
    allow_proof_replace=1
  fi
  write_shell_file_creation_proof \
    "$logical" "$target" "$allow_proof_replace"
}

upsert_owned_shell_block() {
  local target block_id content logical applied_sha current_sha changed
  local id relative entry_present entry_owned previous_sha proof_status
  target="$1"
  block_id="$2"
  content="$3"
  logical="$4"
  validate_logical_id "$logical" || return 2
  managed_block_preflight "$target" "$block_id" || return 2
  applied_sha="$(sha256_text "$content")"
  changed=1
  current_sha=
  if current_sha="$(shell_managed_block_sha \
    "$target" "$block_id" 2>/dev/null)"; then
    if [ "$current_sha" = "$applied_sha" ]; then
      changed=0
    fi
  else
    current_sha=
  fi

  case "$logical" in
    zprofile) id=zprofile ;;
    zshrc) id=zshrc ;;
    ghostty-config) id=ghostty ;;
    *) return 2 ;;
  esac
  relative="$(home_relative_from_absolute "$target")" || return 2
  entry_present=0
  entry_owned=false
  previous_sha=
  if [ -f "$VIBE_MAC_MANIFEST_FILE" ] &&
    json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned" \
      >/dev/null 2>&1; then
    entry_present=1
    manifest_validate_file_entry \
      "$id" "$relative" managed_block "$block_id" "$logical" || return 2
    entry_owned="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned")" || return 2
    previous_sha="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" "files.$id.applied_sha")" || return 2
  fi

  backup_file_once "$target" "$logical" >/dev/null || return 2
  if [ "$changed" -eq 0 ]; then
    if [ "$entry_present" = 1 ] && [ "$entry_owned" = true ]; then
      write_shell_block_creation_proof \
        "$logical" "$target" "$block_id" "$applied_sha"
    fi
    return 0
  fi
  if [ -n "${current_sha:-}" ]; then
    if [ "$entry_present" = 1 ]; then
      if [ "$entry_owned" != true ] || [ "$current_sha" != "$previous_sha" ]; then
        ui_fail "Managed block $id изменён пользователем; upgrade остановлен."
        return 2
      fi
    elif shell_block_creation_proof_matches \
      "$logical" "$target" "$block_id" "$current_sha"; then
      :
    else
      proof_status="$?"
      [ "$proof_status" -eq 1 ] || return 2
      ui_fail "Managed block $id не имеет доказанного ownership."
      return 2
    fi
  elif [ "$entry_present" = 1 ] && [ "$entry_owned" != true ]; then
    ui_fail "Managed block $id не принадлежит installer; upgrade остановлен."
    return 2
  fi
  if is_test_mode &&
    [ "${VIBE_MAC_TEST_CRASH_AFTER_BLOCK_EVIDENCE:-}" = "$logical" ]; then
    return 94
  fi
  managed_block_upsert "$target" "$block_id" "$content" "$logical" ||
    return 2
  write_shell_block_creation_proof \
    "$logical" "$target" "$block_id" "$applied_sha"
}

cleanup_omz_temp() {
  if [ -n "$OMZ_TEMP_DIR" ] && [ -d "$OMZ_TEMP_DIR" ]; then
    remove_temp_tree "$OMZ_TEMP_DIR" || true
  fi
  OMZ_TEMP_DIR=
}

validate_omz_archive_layout() {
  local archive list verbose root
  archive="$1"
  root="ohmyzsh-$OH_MY_ZSH_COMMIT/"
  list="$OMZ_TEMP_DIR/archive-paths.txt"
  verbose="$OMZ_TEMP_DIR/archive-verbose.txt"
  /usr/bin/tar -tzf "$archive" >"$list" || return 2
  if ! /usr/bin/awk -v root="$root" '
    index($0, root) != 1 ||
      $0 ~ /(^|\/)\.\.(\/|$)/ ||
      $0 ~ /(^|\/)\.(\/|$)/ ||
      $0 ~ /^\// ||
      $0 ~ /[\r\t\\]/ {
      bad = 1
    }
    END { exit bad }
  ' "$list"; then
    return 2
  fi
  /usr/bin/tar -tvzf "$archive" >"$verbose" || return 2
  /usr/bin/awk -v root="$root" '
    {
      type = substr($1, 1, 1)
      if (type == "-" || type == "d") next
      if (type != "l" || NF < 3 || $(NF - 1) != "->") {
        bad = 1
        next
      }
      name = $(NF - 2)
      target = $NF
      if (target ~ /^\// || target ~ /(^|\/)\.\.(\/|$)/ ||
        target ~ /(^|\/)\.(\/|$)/ || target ~ /[\r\t\\]/) {
        bad = 1
        next
      }
      relative = substr(name, length(root) + 1)
      if (relative == "plugins/per-directory-history/per-directory-history.plugin.zsh" &&
        target == "per-directory-history.zsh") {
        first = 1
      } else if (relative == "themes/macovsky-ruby.zsh-theme" &&
        target == "macovsky.zsh-theme") {
        second = 1
      } else {
        bad = 1
      }
    }
    END { exit bad || !first || !second }
  ' "$verbose"
}

materialize_omz_symlink() {
  local actual link link_dir relative root root_physical target
  local target_physical temp
  root="$1"
  relative="$2"
  target="$3"
  link="$root/$relative"
  link_dir="${link%/*}"
  [ -L "$link" ] || return 2
  actual="$(/usr/bin/readlink "$link")" || return 2
  [ "$actual" = "$target" ] || return 2
  [ -x /bin/realpath ] || return 2
  root_physical="$(/bin/realpath "$root" 2>/dev/null)" || return 2
  target_physical="$(/bin/realpath "$link_dir/$target" 2>/dev/null)" ||
    return 2
  case "$target_physical" in
    "$root_physical"/*) ;;
    *) return 2 ;;
  esac
  [ -f "$target_physical" ] && [ ! -L "$target_physical" ] || return 2
  temp="$(/usr/bin/mktemp "$link_dir/.omz-materialized.XXXXXX")" ||
    return 2
  if ! /bin/cp -p "$target_physical" "$temp"; then
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  fi
  [ -f "$temp" ] && [ ! -L "$temp" ] || {
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  }
  /bin/unlink "$link" || {
    /bin/unlink "$temp" 2>/dev/null || true
    return 2
  }
  /bin/mv "$temp" "$link"
}

normalize_omz_archive_tree() {
  local source_dir unexpected
  source_dir="$1"
  [ -d "$source_dir" ] && [ ! -L "$source_dir" ] || return 2
  materialize_omz_symlink \
    "$source_dir" \
    plugins/per-directory-history/per-directory-history.plugin.zsh \
    per-directory-history.zsh || return 2
  materialize_omz_symlink \
    "$source_dir" \
    themes/macovsky-ruby.zsh-theme \
    macovsky.zsh-theme || return 2
  unexpected="$(/usr/bin/find "$source_dir" -mindepth 1 \
    ! -type d ! -type f -print -quit)" || return 2
  [ -z "$unexpected" ]
}

install_oh_my_zsh() {
  local archive source_dir url
  if [ -L "$HOME/.oh-my-zsh" ]; then
    ui_fail "$HOME/.oh-my-zsh не может быть symlink."
    return 2
  fi
  if [ -d "$HOME/.oh-my-zsh" ]; then
    if [ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] &&
      [ ! -L "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
      return 0
    fi
    ui_fail "Существующий Oh My Zsh не содержит безопасный oh-my-zsh.sh."
    return 2
  fi
  if [ -e "$HOME/.oh-my-zsh" ]; then
    ui_fail "$HOME/.oh-my-zsh занят не каталогом."
    return 2
  fi

  if is_test_mode && [ -z "${VIBE_MAC_TEST_OMZ_ARCHIVE:-}" ]; then
    /bin/mkdir -p "$HOME/.oh-my-zsh"
    printf '%s\n' '# test Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
    write_omz_creation_proof
    printf '%s\n' "oh-my-zsh:install" >>"$VIBE_MAC_EVENT_LOG"
    return 0
  fi

  OMZ_TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vibe-mac.omz.XXXXXX")"
  /bin/chmod 0700 "$OMZ_TEMP_DIR"
  archive="$OMZ_TEMP_DIR/ohmyzsh.tar.gz"
  url="https://github.com/ohmyzsh/ohmyzsh/archive/$OH_MY_ZSH_COMMIT.tar.gz"
  if is_test_mode && [ -n "${VIBE_MAC_TEST_OMZ_ARCHIVE:-}" ]; then
    [ -f "$VIBE_MAC_TEST_OMZ_ARCHIVE" ] &&
      [ ! -L "$VIBE_MAC_TEST_OMZ_ARCHIVE" ] || return 2
    /bin/cp "$VIBE_MAC_TEST_OMZ_ARCHIVE" "$archive"
  else
    safe_download "$url" "$archive" "$OH_MY_ZSH_ARCHIVE_SHA256"
  fi

  if ! validate_omz_archive_layout "$archive"; then
    ui_fail "Архив Oh My Zsh содержит неожиданные пути."
    return 2
  fi

  /usr/bin/tar -xzf "$archive" -C "$OMZ_TEMP_DIR"
  source_dir="$OMZ_TEMP_DIR/ohmyzsh-$OH_MY_ZSH_COMMIT"
  if [ ! -f "$source_dir/oh-my-zsh.sh" ] || [ -L "$source_dir" ]; then
    ui_fail "Архив Oh My Zsh не прошёл проверку структуры."
    return 2
  fi
  if ! normalize_omz_archive_tree "$source_dir"; then
    ui_fail "Архив Oh My Zsh содержит небезопасные links/special nodes."
    return 2
  fi
  /bin/mv "$source_dir" "$HOME/.oh-my-zsh"
  write_omz_creation_proof
  if is_test_mode; then
    printf '%s\n' "oh-my-zsh:install" >>"$VIBE_MAC_EVENT_LOG"
  fi
  cleanup_omz_temp
}

shell_ready() {
  local zprofile_content zshrc_content zshrc_activation ghostty_content actual
  local zprofile_sha zshrc_sha zshrc_activation_sha ghostty_sha
  [ -d "$HOME/.oh-my-zsh" ] &&
    [ ! -L "$HOME/.oh-my-zsh" ] &&
    [ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] &&
    [ ! -L "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] &&
    [ -f "$HOME/.zprofile" ] &&
    [ ! -L "$HOME/.zprofile" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:zprofile >>>' "$HOME/.zprofile" &&
    [ -f "$HOME/.zshrc" ] &&
    [ ! -L "$HOME/.zshrc" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:zshrc >>>' "$HOME/.zshrc" &&
    [ -f "$HOME/.config/vibe-mac/aliases.zsh" ] &&
    [ ! -L "$HOME/.config/vibe-mac/aliases.zsh" ] &&
    /usr/bin/cmp -s \
      "$VIBE_MAC_ROOT/config/aliases.zsh" \
      "$HOME/.config/vibe-mac/aliases.zsh" &&
    [ -f "$HOME/.config/starship.toml" ] &&
    [ ! -L "$HOME/.config/starship.toml" ] &&
    [ -f "$HOME/Library/Application Support/com.mitchellh.ghostty/config" ] &&
    [ ! -L "$HOME/Library/Application Support/com.mitchellh.ghostty/config" ] &&
    /usr/bin/grep -Fqx '# >>> vibe-mac managed:ghostty >>>' \
      "$HOME/Library/Application Support/com.mitchellh.ghostty/config" ||
    return 1

  zprofile_content="$(zprofile_managed_content)" || return 2
  zshrc_activation="$(zshrc_activation_content)" || return 2
  zshrc_content="$(zshrc_managed_content)" || return 2
  zprofile_sha="$(sha256_text "$zprofile_content")"
  zshrc_sha="$(sha256_text "$zshrc_content")"
  zshrc_activation_sha="$(sha256_text "$zshrc_activation")"
  ghostty_content="$(/bin/cat "$VIBE_MAC_ROOT/config/ghostty.config")" ||
    return 2
  ghostty_sha="$(sha256_text "$ghostty_content")"

  actual="$(shell_managed_block_sha "$HOME/.zprofile" zprofile)" ||
    return 1
  [ "$actual" = "$zprofile_sha" ] || return 1
  actual="$(shell_managed_block_sha "$HOME/.zshrc" zshrc)" || return 1
  if [ "$actual" = "$zshrc_sha" ]; then
    :
  elif [ "$actual" = "$zshrc_activation_sha" ]; then
    zshrc_has_external_omz || return 1
  else
    return 1
  fi
  actual="$(shell_managed_block_sha \
    "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
    ghostty)" || return 1
  [ "$actual" = "$ghostty_sha" ] || return 1
  shell_owned_starship_ready && shell_owned_omz_tree_ready
}

shell_owned_starship_ready() {
  local owned expected actual
  if [ ! -f "$VIBE_MAC_MANIFEST_FILE" ] ||
    ! json_extract_raw "$VIBE_MAC_MANIFEST_FILE" files.starship.owned \
      >/dev/null 2>&1; then
    return 0
  fi
  owned="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" files.starship.owned)" || return 1
  case "$owned" in
    false) return 0 ;;
    true) ;;
    *) return 1 ;;
  esac
  expected="$(sha256_file "$VIBE_MAC_ROOT/config/starship.toml")" || return 1
  actual="$(sha256_file "$HOME/.config/starship.toml")" || return 1
  [ "$actual" = "$expected" ]
}

shell_owned_omz_tree_ready() {
  local owned expected actual
  if [ ! -f "$VIBE_MAC_MANIFEST_FILE" ] ||
    ! json_extract_raw "$VIBE_MAC_MANIFEST_FILE" \
      components.oh_my_zsh.owned >/dev/null 2>&1; then
    return 0
  fi
  owned="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" components.oh_my_zsh.owned)" || return 1
  case "$owned" in
    false) return 0 ;;
    true) ;;
    *) return 1 ;;
  esac
  expected="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" components.oh_my_zsh.tree_sha256)" || return 1
  validate_sha256_or_empty "$expected" && [ -n "$expected" ] || return 1
  actual="$(tree_sha256 "$HOME/.oh-my-zsh")" || return 1
  [ "$actual" = "$expected" ]
}

zshrc_has_external_omz() {
  zshrc_has_external_omz_source "$HOME/.zshrc" zshrc
}

shell_owned_file_matches_manifest() {
  local id target logical relative owned expected actual
  id="$1"
  target="$2"
  logical="$3"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 1
  relative="$(home_relative_from_absolute "$target")" || return 2
  manifest_validate_file_entry \
    "$id" "$relative" owned_file "" "$logical" || return 2
  owned="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned")" || return 2
  [ "$owned" = true ] || return 1
  expected="$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" "files.$id.applied_sha")" || return 2
  actual="$(sha256_file "$target")" || return 2
  [ "$actual" = "$expected" ]
}

shell_preflight() {
  local ghostty_target aliases_target starship_target target parent
  ghostty_target="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  aliases_target="$HOME/.config/vibe-mac/aliases.zsh"
  starship_target="$HOME/.config/starship.toml"

  if [ -L "$HOME/.oh-my-zsh" ] ||
    { [ -e "$HOME/.oh-my-zsh" ] && [ ! -d "$HOME/.oh-my-zsh" ]; }; then
    ui_fail "$HOME/.oh-my-zsh занят небезопасной целью."
    return 2
  fi
  managed_block_preflight "$HOME/.zprofile" zprofile
  managed_block_preflight "$HOME/.zshrc" zshrc
  managed_block_preflight "$ghostty_target" ghostty

  for target in "$aliases_target" "$starship_target"; do
    home_relative_from_absolute "$target" >/dev/null || return 2
    parent="${target%/*}"
    validate_home_dir_path "$parent" || return 2
    if [ -L "$target" ] ||
      { [ -e "$target" ] && [ ! -f "$target" ]; }; then
      ui_fail "Путь $target занят небезопасной целью."
      return 2
    fi
  done
  if [ -e "$aliases_target" ] &&
    ! /usr/bin/cmp -s "$VIBE_MAC_ROOT/config/aliases.zsh" "$aliases_target"; then
    if ! shell_owned_file_matches_manifest \
      aliases "$aliases_target" aliases-zsh; then
      ui_fail "Путь $aliases_target уже занят другим содержимым."
      return 2
    fi
  fi
}

record_shell_file_if_evidence() {
  local id relative kind block_id applied_sha logical evidence
  local preexisting owned status target proof_status entry_present
  id="$1"
  relative="$2"
  kind="$3"
  block_id="$4"
  applied_sha="$5"
  logical="$6"
  entry_present=0
  if json_extract_raw "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned" \
    >/dev/null 2>&1; then
    entry_present=1
    manifest_validate_file_entry \
      "$id" "$relative" "$kind" "$block_id" "$logical" || return 2
    preexisting="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" "files.$id.preexisting")" || return 2
    owned="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" "files.$id.owned")" || return 2
    if [ "$owned" = false ]; then
      return 0
    fi
    [ "$owned" = true ] || return 2
  fi
  if evidence="$(backup_evidence_kind "$logical")"; then
    :
  else
    status="$?"
    [ "$status" -eq 1 ] && return 0
    return 2
  fi
  if [ "$entry_present" = 0 ]; then
    case "$evidence" in file) preexisting=true ;; absent) preexisting=false ;;
      *) return 2 ;;
    esac
  fi
  target="$(home_path "$relative")" || return 2
  case "$kind" in
    owned_file)
      if shell_file_creation_proof_matches \
        "$logical" "$target" "$applied_sha"; then
        owned=true
      else
        proof_status="$?"
        [ "$proof_status" -eq 1 ] || return 2
        preexisting=true
        owned=false
      fi
      ;;
    managed_block)
      if shell_block_creation_proof_matches \
        "$logical" "$target" "$block_id" "$applied_sha"; then
        owned=true
      else
        proof_status="$?"
        [ "$proof_status" -eq 1 ] || return 2
        preexisting=true
        owned=false
      fi
      ;;
    *) return 2 ;;
  esac
  manifest_record_file \
    "$id" "$relative" "$kind" "$block_id" \
    "$preexisting" "$owned" "$applied_sha" "$logical"
}

record_omz_ownership() {
  local owned preexisting evidence status proof_status omz_tree omz_json
  owned="$(json_extract_raw "$VIBE_MAC_MANIFEST_FILE" components.oh_my_zsh.owned)"
  [ "$owned" != true ] || return 0
  preexisting="$(json_extract_raw "$VIBE_MAC_MANIFEST_FILE" components.oh_my_zsh.preexisting)"
  [ "$preexisting" != true ] || return 0
  if evidence="$(backup_evidence_kind oh-my-zsh)"; then
    [ "$evidence" = absent ] || return 2
    if omz_creation_proof_matches; then
      omz_tree="$(tree_sha256 "$HOME/.oh-my-zsh")"
      omz_json="{\"preexisting\":false,\"owned\":true,\"version_before\":\"\",\"version_after\":\"$OH_MY_ZSH_COMMIT\",\"tree_sha256\":\"$omz_tree\"}"
    else
      proof_status="$?"
      [ "$proof_status" -eq 1 ] || return 2
      omz_json='{"preexisting":true,"owned":false,"version_before":"external","version_after":"external","tree_sha256":""}'
    fi
  else
    status="$?"
    [ "$status" -eq 1 ] || return 2
    omz_json='{"preexisting":true,"owned":false,"version_before":"external","version_after":"external","tree_sha256":""}'
  fi
  json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" components.oh_my_zsh "$omz_json"
}

apply_shell() {
  local zprofile_block zshrc_block ghostty_content
  local ghostty_target aliases_target starship_target
  ghostty_target="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  aliases_target="$HOME/.config/vibe-mac/aliases.zsh"
  starship_target="$HOME/.config/starship.toml"

  shell_preflight
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    backup_file_once "$HOME/.oh-my-zsh" oh-my-zsh >/dev/null
    if is_test_mode && [ "${VIBE_MAC_TEST_CRASH_AFTER_OMZ_EVIDENCE:-0}" = 1 ]; then
      return 92
    fi
  fi
  install_oh_my_zsh

  install_owned_shell_file_if_absent \
    "$VIBE_MAC_ROOT/config/aliases.zsh" \
    "$aliases_target" \
    aliases-zsh
  install_owned_shell_file_if_absent \
    "$VIBE_MAC_ROOT/config/starship.toml" \
    "$starship_target" \
    starship-toml

  zprofile_block="$(zprofile_managed_content)" || return 2
  zshrc_block="$(zshrc_activation_content)" || return 2

  if ! zshrc_has_external_omz; then
    zshrc_block="$(zshrc_managed_content)" || return 2
  fi

  upsert_owned_shell_block \
    "$HOME/.zprofile" zprofile "$zprofile_block" zprofile
  upsert_owned_shell_block "$HOME/.zshrc" zshrc "$zshrc_block" zshrc

  ghostty_content="$(/bin/cat "$VIBE_MAC_ROOT/config/ghostty.config")"
  upsert_owned_shell_block \
    "$ghostty_target" ghostty "$ghostty_content" ghostty-config

  if is_test_mode && [ "${VIBE_MAC_TEST_CRASH_AFTER_SHELL_MUTATIONS:-0}" = 1 ]; then
    return 91
  fi
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0
  record_shell_file_if_evidence zprofile .zprofile managed_block zprofile "$(sha256_text "$zprofile_block")" zprofile
  record_shell_file_if_evidence zshrc .zshrc managed_block zshrc "$(sha256_text "$zshrc_block")" zshrc
  record_shell_file_if_evidence ghostty "Library/Application Support/com.mitchellh.ghostty/config" managed_block ghostty "$(sha256_text "$ghostty_content")" ghostty-config
  record_shell_file_if_evidence aliases .config/vibe-mac/aliases.zsh owned_file "" "$(sha256_file "$aliases_target")" aliases-zsh
  record_shell_file_if_evidence starship .config/starship.toml owned_file "" "$(sha256_file "$starship_target")" starship-toml
  record_omz_ownership
}

trap cleanup_omz_temp EXIT
trap 'exit 130' INT TERM HUP

case "${1:-}" in
  plan)
    ui_info "Настрою системный zsh, pinned Oh My Zsh, Starship и Ghostty."
    ;;
  detect|verify)
    shell_ready
    ;;
  apply)
    apply_shell
    ;;
  *)
    ui_fail "40-shell: неизвестное действие."
    exit 2
    ;;
esac
