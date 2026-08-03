#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    init_runtime_layout
    state_init "$PROJECT_ROOT/state/progress-template.json" "$VIBE_MAC_STATE_FILE"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  setup_homebrew_fixture
  setup_shell_fixture
  setup_release_fixture
  : >"$VIBE_MAC_EVENT_LOG"
}

setup_shell_fixture() {
  /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
}

make_prefix_command() {
  local name body
  name="$1"
  body="$2"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' "$body"
  } >"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$name"
  chmod 0755 "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$name"
}

setup_homebrew_fixture() {
  local name
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"
  mkdir -p "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin"
  make_prefix_command brew '
    case "${1:-}" in
      --prefix) printf "%s\n" "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX" ;;
      --version) printf "%s\n" "Homebrew 4.6.0" ;;
      *) exit 2 ;;
    esac
  '
  for name in git gh starship rg fd fzf bat eza jq tree zoxide mise uv; do
    make_prefix_command "$name" 'exit 0'
  done
  PATH="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
}

setup_release_fixture() {
  local version release archive_sha tree_sha id launcher sha
  version=0.1.0-test
  release="$VIBE_MAC_RUNTIME_ROOT/releases/$version"
  archive_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$release" "$VIBE_MAC_RUNTIME_ROOT/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$release/install.sh"
  chmod 0700 "$release/install.sh"
  tree_sha="$(/bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    release_tree_sha256 "$1"
  ' _ "$release")"
  printf '%s\n' "$archive_sha" >"$release/.bundle-sha256"
  printf '%s\n' "$tree_sha" >"$release/.bundle-tree-sha256"
  ln -s "releases/$version" "$VIBE_MAC_RUNTIME_ROOT/current"
  for id in verify doctor uninstall; do
    launcher="$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$id"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' $id" >"$launcher"
    chmod 0700 "$launcher"
    sha="$(shasum -a 256 "$launcher" | awk '{print $1}')"
    /bin/bash -c '
      source "$PROJECT_ROOT/lib/util.sh"
      json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" "launchers.$1" \
        "{\"path_kind\":\"runtime_relative\",\"path\":\"bin/vibe-mac-$1\",\"sha256\":\"$2\",\"owned\":true}"
    ' _ "$id" "$sha"
  done
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" releases.current \
      "{\"version\":\"$1\",\"path_kind\":\"runtime_relative\",\"path\":\"releases/$1\",\"archive_sha256\":\"$2\",\"tree_sha256\":\"$3\",\"owned\":true}"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" current_link \
      "{\"path_kind\":\"runtime_relative\",\"path\":\"current\",\"target\":\"releases/$1\",\"owned\":true}"
  ' _ "$version" "$archive_sha" "$tree_sha"
}

unsafe_release_tree_sha256() {
  local root
  root="$1"
  (
    cd "$root" || exit 2
    /usr/bin/find . -mindepth 1 \
      ! -path './.bundle-sha256' \
      ! -path './.bundle-tree-sha256' \
      -print | LC_ALL=C /usr/bin/sort |
      while IFS= read -r path; do
        if [ -f "$path" ]; then
          printf 'F\t%s\t%s\t%s\n' \
            "$(mode_of "$path")" \
            "$(shasum -a 256 "$path" | awk '{print $1}')" \
            "$path"
        elif [ -d "$path" ]; then
          printf 'D\t%s\t-\t%s\n' "$(mode_of "$path")" "$path"
        else
          exit 2
        fi
      done
  ) | shasum -a 256 | awk '{print $1}'
}

setup_packaged_doctor_fixture() {
  local commit release tree_sha
  commit=1111111111111111111111111111111111111111
  release="$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test"
  cp "$PROJECT_ROOT/doctor.sh" "$release/doctor.sh"
  cp -R "$PROJECT_ROOT/config" "$release/config"
  cp -R "$PROJECT_ROOT/lib" "$release/lib"
  /usr/bin/sed -i.bak \
    "s/\\\$Format:%H\\\$/$commit/" "$release/doctor.sh"
  /bin/unlink "$release/doctor.sh.bak"
  grep -Fq "VIBE_MAC_DOCTOR_BUILD_COMMIT='$commit'" \
    "$release/doctor.sh"
  tree_sha="$(/bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    release_tree_sha256 "$1"
  ' _ "$release")"
  printf '%s\n' "$tree_sha" >"$release/.bundle-tree-sha256"
  printf '%s\n' "$release"
}

tree_snapshot() {
  {
    find "$TEST_ROOT" -mindepth 1 -type f -exec shasum -a 256 {} \; |
      LC_ALL=C sort
    find "$TEST_ROOT" -mindepth 1 -print | LC_ALL=C sort
  }
}

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

make_lock() {
  local pid
  pid="$1"
  mkdir -p "$VIBE_MAC_LOCK_DIR"
  printf '%s\n' "$pid" >"$VIBE_MAC_LOCK_DIR/pid"
  printf '%s\n' "0.1.0-dev" >"$VIBE_MAC_LOCK_DIR/version"
  printf '%s\n' "2026-08-02T00:00:00Z" >"$VIBE_MAC_LOCK_DIR/started_at"
}

@test "doctor без флагов диагностирует stale lock без единой записи" {
  make_lock 99999999
  before="$(tree_snapshot)"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"stale lock"* ]]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
  [ "$before" = "$(tree_snapshot)" ]
  assert_no_events
}

@test "doctor --repair без подтверждения ничего не исправляет" {
  make_lock 99999999
  chmod 0755 "$VIBE_MAC_RUNTIME_ROOT"
  export VIBE_MAC_TEST_RESPONSE=нет

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 1 ]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
  [ "$(mode_of "$VIBE_MAC_RUNTIME_ROOT")" = 755 ]
}

@test "doctor --repair чинит только stale lock и точный mode после да" {
  make_lock 99999999
  chmod 0755 "$VIBE_MAC_RUNTIME_ROOT"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 0 ]
  assert_path_absent "$VIBE_MAC_LOCK_DIR"
  [ "$(mode_of "$VIBE_MAC_RUNTIME_ROOT")" = 700 ]
}

@test "doctor никогда не удаляет lock живого процесса" {
  make_lock "$$"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 1 ]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
  [[ "$output" == *"активный lock"* ]]
}

@test "повреждённый manifest даёт exit 2 и остаётся byte-for-byte" {
  printf '%s\n' '{broken' >"$VIBE_MAC_MANIFEST_FILE"
  before="$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [ "$before" = "$(shasum -a 256 "$VIBE_MAC_MANIFEST_FILE" | awk '{print $1}')" ]
}

@test "extra lock entry делает repair fail-closed без частичного удаления" {
  make_lock 99999999
  printf '%s\n' unexpected >"$VIBE_MAC_LOCK_DIR/extra"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 2 ]
  [ -f "$VIBE_MAC_LOCK_DIR/pid" ]
  [ -f "$VIBE_MAC_LOCK_DIR/extra" ]
}

@test "corrupt manifest блокирует удаление отдельно валидного stale lock" {
  make_lock 99999999
  printf '%s\n' '{broken' >"$VIBE_MAC_MANIFEST_FILE"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 2 ]
  [ -d "$VIBE_MAC_LOCK_DIR" ]
}

@test "backup hash mismatch является integrity blocker" {
  printf '%s\n' aliases >"$HOME/.config/vibe-mac/aliases.zsh"
  applied_sha="$(shasum -a 256 "$HOME/.config/vibe-mac/aliases.zsh" |
    awk '{print $1}')"
  /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_set_json_atomic "$VIBE_MAC_MANIFEST_FILE" files.aliases.applied_sha \
      "\"$1\""
  ' _ "$applied_sha"
  backup_relative="$(/bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    json_extract_raw "$VIBE_MAC_MANIFEST_FILE" files.aliases.backup.path
  ')"
  printf '%s\n' tampered >>"$HOME/$backup_relative"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"backup evidence"* ]]
}

@test "doctor замечает Homebrew вне expected PATH и конфликтующий executable" {
  mkdir -p "$TEST_ROOT/conflict-bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    >"$TEST_ROOT/conflict-bin/starship"
  chmod 0755 "$TEST_ROOT/conflict-bin/starship"
  PATH="$TEST_ROOT/conflict-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  before="$(tree_snapshot)"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Homebrew bin отсутствует в PATH"* ]]
  [[ "$output" == *"starship разрешается вне expected Homebrew bin"* ]]
  [ "$before" = "$(tree_snapshot)" ]
  assert_no_events
}

@test "doctor default и dry-run не исполняют exact Homebrew" {
  make_prefix_command brew \
    'printf "%s\n" "brew $*" >>"$VIBE_MAC_EVENT_LOG"; exit 0'
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"
  [ "$status" -eq 0 ]
  assert_no_events

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --dry-run
  [ "$status" -eq 0 ]
  assert_no_events
}

@test "doctor блокирует external Homebrew executable symlink без execute" {
  local external
  external="$TEST_ROOT/external-starship"
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" executed:starship >>"$VIBE_MAC_EVENT_LOG"' \
    'exit 0' >"$external"
  chmod 0755 "$external"
  /bin/unlink "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/starship"
  /bin/ln -s "$external" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/starship"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"starship"*"canonical containment"* ]]
  assert_no_events
}

@test "doctor допускает internal Homebrew Cellar executable symlink" {
  local cellar
  cellar="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/starship/1/bin"
  mkdir -p "$cellar"
  /bin/mv "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/starship" \
    "$cellar/starship"
  /bin/ln -s ../Cellar/starship/1/bin/starship \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/starship"
  : >"$VIBE_MAC_EVENT_LOG"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 0 ]
  assert_no_events
}

@test "doctor замечает tamper owned Oh My Zsh tree" {
  printf '%s\n' 'echo tampered' >>"$HOME/.oh-my-zsh/oh-my-zsh.sh"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Oh My Zsh изменён после установки"* ]]
}

@test "doctor сообщает exact-template issue при tamper owned Starship" {
  printf '%s\n' '# starship-tampered' >>"$HOME/.config/starship.toml"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Owned starship не совпадает с exact template"* ]]
}

@test "doctor отвергает activation-only без внешнего Oh My Zsh source" {
  printf '%s\n' 'source "$ZSH/oh-my-zsh.sh"' >>"$HOME/.zshrc"
  /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  sed -i.bak '/^source "$ZSH\/oh-my-zsh.sh"$/d' "$HOME/.zshrc"
  /bin/unlink "$HOME/.zshrc.bak"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"managed block zshrc изменён"* ]]
}

@test "doctor замечает отсутствующий обязательный managed block" {
  /bin/unlink "$HOME/.zprofile"
  before="$(tree_snapshot)"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"managed block zprofile отсутствует"* ]]
  [ "$before" = "$(tree_snapshot)" ]
}

@test "doctor --repair восстанавливает только точный owned managed block" {
  /bin/unlink "$HOME/.zprofile"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 0 ]
  grep -Fqx '# >>> vibe-mac managed:zprofile >>>' "$HOME/.zprofile"
  grep -Fqx 'export PATH="$HOME/.vibe-mac/bin:$HOME/.local/bin:$PATH"' \
    "$HOME/.zprofile"
  grep -Fqx \
    '  eval "$("$_vibe_mac_mise" activate zsh --shims)"' \
    "$HOME/.zprofile"
}

@test "doctor repair восстанавливает байт-в-байт canonical shell blocks" {
  zprofile_before="$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')"
  zshrc_before="$(shasum -a 256 "$HOME/.zshrc" | awk '{print $1}')"
  /bin/unlink "$HOME/.zprofile"
  /bin/unlink "$HOME/.zshrc"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 0 ]
  [ "$zprofile_before" = \
    "$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')" ]
  [ "$zshrc_before" = \
    "$(shasum -a 256 "$HOME/.zshrc" | awk '{print $1}')" ]
}

@test "doctor --repair не перезаписывает изменённый managed block" {
  sed -i.bak \
    's#export PATH=.*#export PATH="/user/custom:$PATH"#' "$HOME/.zprofile"
  /bin/unlink "$HOME/.zprofile.bak"
  before="$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')"
  export VIBE_MAC_TEST_RESPONSE=да

  run /bin/bash "$PROJECT_ROOT/doctor.sh" --repair

  [ "$status" -eq 1 ]
  [ "$before" = "$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')" ]
  [[ "$output" == *"allowlisted автоматических действий нет"* ]]
}

@test "изменённый release tree является integrity blocker и остаётся read-only" {
  printf '%s\n' tampered >>"$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test/install.sh"
  before="$(tree_snapshot)"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"release tree"* ]]
  [ "$before" = "$(tree_snapshot)" ]
}

@test "doctor отклоняет string manifest schema как integrity blocker" {
  "$VIBE_MAC_PLUTIL_BIN" -replace schema_version -string 1 -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"schema_version"* ]]
}

@test "doctor отклоняет forged release owned string" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace releases.current.owned -string true -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"releases.current.owned имеет неверный тип"* ]]
}

@test "doctor отклоняет forged current_link owned string" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace current_link.owned -string true -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"current_link.owned имеет неверный тип"* ]]
}

@test "doctor отклоняет forged launcher owned string" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace launchers.doctor.owned -string true -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"launcher doctor owned имеет неверный тип"* ]]
}

@test "doctor отклоняет forged Oh My Zsh owned string" {
  "$VIBE_MAC_PLUTIL_BIN" \
    -replace components.oh_my_zsh.owned -string true -- \
    "$VIBE_MAC_MANIFEST_FILE"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"Oh My Zsh ownership имеет неверный тип"* ]]
}

@test "packaged doctor pre-source tree walker отклоняет TAB path" {
  local physical_home release tab_path unsafe_sha
  release="$(setup_packaged_doctor_fixture)"
  tab_path="$release/path"$'\t'"with-tab"
  printf '%s\n' tabbed >"$tab_path"
  unsafe_sha="$(unsafe_release_tree_sha256 "$release")"
  printf '%s\n' "$unsafe_sha" >"$release/.bundle-tree-sha256"
  physical_home="$(cd "$HOME" && pwd -P)"

  run /usr/bin/env HOME="$physical_home" \
    /bin/bash "$release/doctor.sh" --help

  [ "$status" -eq 2 ]
  [[ "$output" == *"release tree нельзя безопасно проверить"* ]]
}

@test "symlink ancestor release является integrity blocker" {
  outside="$TEST_ROOT/outside-releases"
  /bin/mv "$VIBE_MAC_RUNTIME_ROOT/releases" "$outside"
  ln -s "$outside" "$VIBE_MAC_RUNTIME_ROOT/releases"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"release path"* ]]
  [ -f "$outside/0.1.0-test/install.sh" ]
}

@test "изменённый launcher является integrity blocker" {
  printf '%s\n' tampered >>"$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-doctor"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"launcher doctor"* ]]
}

@test "current обязан совпадать с typed manifest" {
  /bin/unlink "$VIBE_MAC_RUNTIME_ROOT/current"
  ln -s releases/another "$VIBE_MAC_RUNTIME_ROOT/current"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"current не совпадает с manifest"* ]]
}

@test "bundle marker обязан совпадать с manifest" {
  printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    >"$VIBE_MAC_RUNTIME_ROOT/releases/0.1.0-test/.bundle-sha256"

  run /bin/bash "$PROJECT_ROOT/doctor.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"archive marker"* ]]
}
