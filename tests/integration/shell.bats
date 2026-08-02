#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_INSTALL_ID=test-install
}

@test "managed block сохраняет старый текст и не дублируется" {
  target="$HOME/.zshrc"
  printf '%s\n' '# user setting' >"$target"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    managed_block_upsert "$1" shell "export VIBE_TEST=1" zshrc
    managed_block_upsert "$1" shell "export VIBE_TEST=1" zshrc
  ' _ "$target"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^# user setting$' "$target")" -eq 1 ]
  [ "$(grep -c '^# >>> vibe-mac managed:shell >>>$' "$target")" -eq 1 ]
  [ "$(grep -c '^export VIBE_TEST=1$' "$target")" -eq 1 ]
  [ "$(find "$VIBE_MAC_BACKUP_ROOT" -type f | wc -l | tr -d ' ')" -eq 1 ]
}

@test "malformed managed block блокирует запись и сохраняет файл" {
  target="$HOME/.zshrc"
  printf '%s\n' '# >>> vibe-mac managed:shell >>>' 'broken' >"$target"
  before="$(shasum -a 256 "$target" | awk '{print $1}')"

  run /bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    managed_block_upsert "$1" shell "new" zshrc
  ' _ "$target"

  [ "$status" -ne 0 ]
  after="$(shasum -a 256 "$target" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "shell step не изменяет существующий Oh My Zsh и идемпотентен" {
  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' keep >"$HOME/.oh-my-zsh/sentinel"
  printf '%s\n' '# my zsh' >"$HOME/.zshrc"
  printf '%s\n' '# my profile' >"$HOME/.zprofile"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  first="$(find "$HOME" -type f -not -path '*/.vibe-mac-backup/*' -exec shasum -a 256 {} \; | LC_ALL=C sort)"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  second="$(find "$HOME" -type f -not -path '*/.vibe-mac-backup/*' -exec shasum -a 256 {} \; | LC_ALL=C sort)"

  [ "$first" = "$second" ]
  [ "$(cat "$HOME/.oh-my-zsh/sentinel")" = keep ]
  [ "$(grep -c '^# >>> vibe-mac managed:zshrc >>>$' "$HOME/.zshrc")" -eq 1 ]
  [ "$(grep -c '^# >>> vibe-mac managed:zprofile >>>$' "$HOME/.zprofile")" -eq 1 ]
}

@test "shell step fail-closed при занятом aliases path" {
  mkdir -p "$HOME/.config/vibe-mac" "$HOME/.oh-my-zsh"
  printf '%s\n' 'user content' >"$HOME/.config/vibe-mac/aliases.zsh"
  before="$(shasum -a 256 "$HOME/.config/vibe-mac/aliases.zsh" | awk '{print $1}')"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  [ "$status" -ne 0 ]
  after="$(shasum -a 256 "$HOME/.config/vibe-mac/aliases.zsh" | awk '{print $1}')"
  [ "$before" = "$after" ]
  assert_path_absent "$HOME/.zshrc"
}

@test "shell step записывает typed ownership и hashes в manifest" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]

  for key in files.zprofile files.zshrc files.ghostty files.aliases files.starship; do
    run "$VIBE_MAC_PLUTIL_BIN" -extract "$key" raw -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"owned":true'* ]]
    [[ "$output" == *'"applied_sha":"'* ]]
    [[ "$output" == *'"backup":{'* ]]
  done
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract components.oh_my_zsh raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"owned":true'* ]]
  [[ "$output" == *'"tree_sha256":"'* ]]
}
