#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VIBE_MAC_ROOT="${VIBE_MAC_ROOT:-$(cd "$STEP_DIR/.." && pwd -P)}"
export VIBE_MAC_ROOT

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"

BREW_TEMP_DIR=

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
  [ -d "$font_dir" ] || return 1
  /usr/bin/find "$font_dir" -maxdepth 1 -type f \
    \( -iname 'JetBrainsMono*NerdFont*.ttf' -o \
       -iname 'JetBrainsMono*NerdFont*.otf' \) -print -quit |
    /usr/bin/grep -q .
}

formula_preexisting() {
  local name command_name
  name="$1"
  if brew list --formula "$name" >/dev/null 2>&1; then
    return 0
  fi
  if is_test_mode; then
    case " ${VIBE_MAC_TEST_EXTERNAL_FORMULAE:-} " in
      *" $name "*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  command_name="$(formula_command "$name")"
  have "$command_name"
}

cask_preexisting() {
  local name
  name="$1"
  if brew list --cask "$name" >/dev/null 2>&1; then
    return 0
  fi
  if is_test_mode; then
    case " ${VIBE_MAC_TEST_EXTERNAL_CASKS:-} " in
      *" $name "*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$name" in
    ghostty)
      [ -d /Applications/Ghostty.app ]
      ;;
    font-jetbrains-mono-nerd-font)
      font_present
      ;;
    claude-code)
      have claude
      ;;
    codex)
      have codex
      ;;
    cursor)
      [ -d /Applications/Cursor.app ]
      ;;
    cursor-cli)
      have cursor-agent
      ;;
    zed)
      [ -d /Applications/Zed.app ]
      ;;
    raycast)
      [ -d /Applications/Raycast.app ]
      ;;
    visual-studio-code)
      [ -d "/Applications/Visual Studio Code.app" ]
      ;;
    *)
      return 2
      ;;
  esac
}

build_skip_lists() {
  local name
  FORMULA_SKIP=
  CASK_SKIP=
  for name in $(formulae); do
    if formula_preexisting "$name"; then
      FORMULA_SKIP="${FORMULA_SKIP:+$FORMULA_SKIP }$name"
    fi
  done
  for name in $(casks); do
    if cask_preexisting "$name"; then
      CASK_SKIP="${CASK_SKIP:+$CASK_SKIP }$name"
    fi
  done
  if [ "${EXTRAS:-0}" = "1" ]; then
    for name in $(extra_casks); do
      if cask_preexisting "$name"; then
        CASK_SKIP="${CASK_SKIP:+$CASK_SKIP }$name"
      fi
    done
  fi
  export FORMULA_SKIP CASK_SKIP
}

formula_capabilities_ready() {
  local name command_name
  for name in $(formulae); do
    command_name="$(formula_command "$name")"
    have "$command_name" || return 1
  done
}

cask_capabilities_ready() {
  [ -d /Applications/Ghostty.app ] &&
    font_present &&
    have claude &&
    have codex &&
    [ -d /Applications/Cursor.app ] &&
    have cursor-agent
}

extras_ready() {
  [ "${EXTRAS:-0}" != "1" ] ||
    {
      [ -d /Applications/Zed.app ] &&
        [ -d /Applications/Raycast.app ] &&
        [ -d "/Applications/Visual Studio Code.app" ]
    }
}

bundle_ready() {
  if is_test_mode && [ -n "${VIBE_MAC_TEST_BUNDLE_MARKER:-}" ]; then
    [ -f "$VIBE_MAC_TEST_BUNDLE_MARKER" ]
    return
  fi
  configure_homebrew_path
  have brew &&
    formula_capabilities_ready &&
    cask_capabilities_ready &&
    extras_ready
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

record_packages() {
  local before_formula after_formula before_cask after_cask
  local name before after preexisting owned owner names existing_owned
  before_formula="$1"
  after_formula="$2"
  before_cask="$3"
  after_cask="$4"
  [ -f "$VIBE_MAC_MANIFEST_FILE" ] || return 0

  for name in $(formulae); do
    before="$(snapshot_version "$before_formula" "$name")"
    after="$(snapshot_version "$after_formula" "$name")"
    existing_owned="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" \
      "packages.formulae.$name.owned" 2>/dev/null || true)"
    if [ "$existing_owned" = "true" ]; then
      preexisting=false
      owned=true
      owner=vibe-mac
      [ -n "$after" ] || after=installed
    elif [ -n "$before" ]; then
      preexisting=true
      owned=false
      owner=homebrew
    elif word_in_list "$name" "$FORMULA_SKIP"; then
      preexisting=true
      owned=false
      owner=external
      before=external
      [ -n "$after" ] || after=external
    else
      preexisting=false
      owned=true
      owner=vibe-mac
      [ -n "$after" ] || after=installed
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
    before="$(snapshot_version "$before_cask" "$name")"
    after="$(snapshot_version "$after_cask" "$name")"
    existing_owned="$(json_extract_raw \
      "$VIBE_MAC_MANIFEST_FILE" \
      "packages.casks.$name.owned" 2>/dev/null || true)"
    if [ "$existing_owned" = "true" ]; then
      preexisting=false
      owned=true
      owner=vibe-mac
      [ -n "$after" ] || after=installed
    elif [ -n "$before" ]; then
      preexisting=true
      owned=false
      owner=homebrew
    elif word_in_list "$name" "$CASK_SKIP"; then
      preexisting=true
      owned=false
      owner=external
      before=external
      [ -n "$after" ] || after=external
    else
      preexisting=false
      owned=true
      owner=vibe-mac
      [ -n "$after" ] || after=installed
    fi
    manifest_record_package \
      casks "$name" "$preexisting" "$owned" "$owner" "$before" "$after"
  done
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
  done <"$delta_file"
  delta_json="$delta_json]"
  manifest_record_dependency_delta "$delta_json"
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
    brew bundle install --file="$file" --no-upgrade
}

apply_bundle() {
  local before_formula after_formula before_cask after_cask
  configure_homebrew_path
  if ! have brew; then
    ui_fail "Homebrew не найден; сначала нужен шаг 20-homebrew."
    return 1
  fi

  build_skip_lists
  BREW_TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vibe-mac.brew.XXXXXX")"
  /bin/chmod 0700 "$BREW_TEMP_DIR"
  before_formula="$BREW_TEMP_DIR/formula-before.txt"
  after_formula="$BREW_TEMP_DIR/formula-after.txt"
  before_cask="$BREW_TEMP_DIR/cask-before.txt"
  after_cask="$BREW_TEMP_DIR/cask-after.txt"

  brew list --formula --versions >"$before_formula"
  brew list --cask --versions >"$before_cask"
  record_packages "$before_formula" "$before_formula" "$before_cask" "$before_cask"

  if bundle_ready; then
    /bin/cp "$before_formula" "$after_formula"
    /bin/cp "$before_cask" "$after_cask"
    record_packages \
      "$before_formula" "$after_formula" "$before_cask" "$after_cask"
    record_dependency_delta "$before_formula" "$after_formula"
    cleanup_brew_temp
    return 0
  fi

  run_bundle_file "$VIBE_MAC_ROOT/Brewfile"
  if [ "${EXTRAS:-0}" = "1" ]; then
    run_bundle_file "$VIBE_MAC_ROOT/Brewfile.extras"
  fi

  brew list --formula --versions >"$after_formula"
  brew list --cask --versions >"$after_cask"
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
    ui_info "Установлю exact Brewfile без upgrade, cleanup, relink или zap."
    if [ "${EXTRAS:-0}" = "1" ]; then
      ui_info "Добавлю только Zed, Raycast и Visual Studio Code."
    fi
    ;;
  detect|verify)
    bundle_ready
    ;;
  apply)
    apply_bundle
    ;;
  *)
    ui_fail "30-brew-bundle: неизвестное действие."
    exit 2
    ;;
esac
