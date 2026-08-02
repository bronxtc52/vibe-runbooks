#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
  load_helpers
  export VIBE_MAC_INSTALL_ID=test-install
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$TEST_ROOT/homebrew"
  mkdir -p \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin" \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/opt/fzf/shell"
}

make_omz_archive_fixture() {
  local archive first_target kind root second_target staging
  archive="$1"
  first_target="$2"
  second_target="$3"
  kind="${4:-safe}"
  # shellcheck source=config/versions.env
  source "$PROJECT_ROOT/config/versions.env"
  staging="${archive%.tar.gz}.tree"
  root="$staging/ohmyzsh-$OH_MY_ZSH_COMMIT"
  mkdir -p \
    "$root/plugins/per-directory-history" \
    "$root/themes"
  printf '%s\n' '# fixture Oh My Zsh' >"$root/oh-my-zsh.sh"
  if [ "$kind" != dangling ]; then
    printf '%s\n' '# per-directory-history' \
      >"$root/plugins/per-directory-history/per-directory-history.zsh"
  fi
  printf '%s\n' '# macovsky theme' >"$root/themes/macovsky.zsh-theme"
  /bin/ln -s "$first_target" \
    "$root/plugins/per-directory-history/per-directory-history.plugin.zsh"
  /bin/ln -s "$second_target" \
    "$root/themes/macovsky-ruby.zsh-theme"
  if [ "$kind" = external ]; then
    /bin/ln -s /tmp/outside "$root/plugins/unexpected.plugin.zsh"
  fi
  /usr/bin/tar -czf "$archive" -C "$staging" \
    "ohmyzsh-$OH_MY_ZSH_COMMIT"
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
  printf '%s\n' '# existing Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
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

@test "clean first-run materializes pinned Oh My Zsh internal symlinks" {
  local archive first_link first_target manifest_tree second_link second_target
  archive="$TEST_ROOT/omz-legit.tar.gz"
  make_omz_archive_fixture \
    "$archive" per-directory-history.zsh macovsky.zsh-theme safe
  export VIBE_MAC_TEST_OMZ_ARCHIVE="$archive"
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init \
      "$PROJECT_ROOT/state/manifest-template.json" \
      "$VIBE_MAC_MANIFEST_FILE"
  '

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  [ "$status" -eq 0 ]
  first_link="$HOME/.oh-my-zsh/plugins/per-directory-history/per-directory-history.plugin.zsh"
  first_target="$HOME/.oh-my-zsh/plugins/per-directory-history/per-directory-history.zsh"
  second_link="$HOME/.oh-my-zsh/themes/macovsky-ruby.zsh-theme"
  second_target="$HOME/.oh-my-zsh/themes/macovsky.zsh-theme"
  [ -f "$first_link" ] && [ ! -L "$first_link" ]
  [ -f "$second_link" ] && [ ! -L "$second_link" ]
  /usr/bin/cmp -s "$first_link" "$first_target"
  /usr/bin/cmp -s "$second_link" "$second_target"
  ! /usr/bin/find "$HOME/.oh-my-zsh" -mindepth 1 \
    ! -type d ! -type f -print -quit | /usr/bin/grep -q .
  manifest_tree="$("$VIBE_MAC_PLUTIL_BIN" \
    -extract components.oh_my_zsh.tree_sha256 raw -- \
    "$VIBE_MAC_MANIFEST_FILE")"
  [ -n "$manifest_tree" ]
  [ "$manifest_tree" = "$(/bin/bash -c '
    source "$PROJECT_ROOT/lib/util.sh"
    tree_sha256 "$HOME/.oh-my-zsh"
  ')" ]

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" verify
  [ "$status" -eq 0 ]
}

@test "Oh My Zsh archive rejects absolute parent external and dangling links" {
  local archive kind
  for kind in absolute parent external dangling; do
    archive="$TEST_ROOT/omz-$kind.tar.gz"
    case "$kind" in
      absolute)
        make_omz_archive_fixture \
          "$archive" /tmp/outside macovsky.zsh-theme safe
        ;;
      parent)
        make_omz_archive_fixture \
          "$archive" ../outside macovsky.zsh-theme safe
        ;;
      external)
        make_omz_archive_fixture \
          "$archive" per-directory-history.zsh macovsky.zsh-theme external
        ;;
      dangling)
        make_omz_archive_fixture \
          "$archive" per-directory-history.zsh macovsky.zsh-theme dangling
        ;;
    esac
    export VIBE_MAC_TEST_OMZ_ARCHIVE="$archive"

    run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

    [ "$status" -eq 2 ]
    [ ! -e "$HOME/.oh-my-zsh" ]
    [ ! -L "$HOME/.oh-my-zsh" ]
  done
}

@test "комментарий про Oh My Zsh не заменяет реальный source" {
  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' '# test Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
  printf '%s\n' \
    '# source "$HOME/.oh-my-zsh/oh-my-zsh.sh"' \
    '# oh-my-zsh.sh is configured later' >"$HOME/.zshrc"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc '  source "$ZSH/oh-my-zsh.sh"' "$HOME/.zshrc")" -eq 1 ]
}

@test "реальный внешний Oh My Zsh source не дублируется" {
  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' '# test Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
  printf '%s\n' \
    'export ZSH="$HOME/.oh-my-zsh"' \
    'source "$ZSH/oh-my-zsh.sh"' >"$HOME/.zshrc"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc 'source "$ZSH/oh-my-zsh.sh"' "$HOME/.zshrc")" -eq 1 ]
  ! /usr/bin/awk '
    $0 == "# >>> vibe-mac managed:zshrc >>>" { inside = 1; next }
    $0 == "# <<< vibe-mac managed:zshrc <<<" { inside = 0 }
    inside && $0 ~ /oh-my-zsh\.sh/ { found = 1 }
    END { exit !found }
  ' "$HOME/.zshrc"
}

@test "неисполняемый conditional Oh My Zsh source не считается внешним" {
  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' '# test Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
  printf '%s\n' \
    'if false; then' \
    'source "$ZSH/oh-my-zsh.sh"' \
    'fi' \
    'echo '\''source "$ZSH/oh-my-zsh.sh"'\''' >"$HOME/.zshrc"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  [ "$status" -eq 0 ]
  /usr/bin/awk '
    $0 == "# >>> vibe-mac managed:zshrc >>>" { inside = 1; next }
    $0 == "# <<< vibe-mac managed:zshrc <<<" { inside = 0 }
    inside && $0 == "  source \"$ZSH/oh-my-zsh.sh\"" { found = 1 }
    END { exit !found }
  ' "$HOME/.zshrc"
}

@test "activation-only block красный после удаления внешнего Oh My Zsh source" {
  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' '# test Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
  printf '%s\n' \
    'export ZSH="$HOME/.oh-my-zsh"' \
    'source "$ZSH/oh-my-zsh.sh"' >"$HOME/.zshrc"
  /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  sed -i.bak '/^source "$ZSH\/oh-my-zsh.sh"$/d' "$HOME/.zshrc"
  /bin/unlink "$HOME/.zshrc.bak"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" verify

  [ "$status" -ne 0 ]
}

@test "generated shell config не исполняет init trojans из ~/.local/bin" {
  trusted_log="$TEST_ROOT/trusted-init.log"
  export trusted_log
  mkdir -p "$HOME/.local/bin"
  for command_name in brew mise zoxide starship; do
    make_recording_command "$command_name" 0
    cp "$TEST_ROOT/fake-bin/$command_name" "$HOME/.local/bin/$command_name"
    {
      printf '%s\n' '#!/bin/sh'
      printf '%s\n' \
        'printf "trusted:%s\n" "${0##*/}" >>"$trusted_log"' \
        'printf "%s\n" :'
    } >"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
    chmod 0755 \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  printf '%s\n' \
    'printf "%s\n" trusted:fzf-completion >>"$trusted_log"' \
    >"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/opt/fzf/shell/completion.zsh"
  printf '%s\n' \
    'printf "%s\n" trusted:fzf-key-bindings >>"$trusted_log"' \
    >"$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/opt/fzf/shell/key-bindings.zsh"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  : >"$VIBE_MAC_EVENT_LOG"

  run /usr/bin/env HOME="$HOME" /bin/zsh -f -c \
    'source "$HOME/.zprofile"; source "$HOME/.zshrc"'

  [ "$status" -eq 0 ]
  assert_no_events
  [ "$(grep -Fxc trusted:brew "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:mise "$trusted_log")" -eq 2 ]
  [ "$(grep -Fxc trusted:zoxide "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:starship "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:fzf-completion "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:fzf-key-bindings "$trusted_log")" -eq 1 ]
}

@test "generated shell resolver отклоняет external Homebrew symlinks и aliases" {
  local command_name external
  external="$TEST_ROOT/external-shell-targets"
  mkdir -p "$external"
  for command_name in brew mise zoxide starship; do
    printf '%s\n' \
      '#!/bin/sh' \
      'printf "executed:%s\n" "${0##*/}" >>"$VIBE_MAC_EVENT_LOG"' \
      'printf "%s\n" :' >"$external/$command_name"
    chmod 0755 "$external/$command_name"
    /bin/ln -s "$external/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  for command_name in completion.zsh key-bindings.zsh; do
    printf 'printf "executed:fzf-%s\\n" >>"$VIBE_MAC_EVENT_LOG"\n' \
      "$command_name" >"$external/$command_name"
    /bin/ln -s "$external/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/opt/fzf/shell/$command_name"
  done

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  printf '%s\n' \
    'printf "%s\n" executed:aliases >>"$VIBE_MAC_EVENT_LOG"' \
    >"$external/aliases.zsh"
  /bin/unlink "$HOME/.config/vibe-mac/aliases.zsh"
  /bin/ln -s "$external/aliases.zsh" \
    "$HOME/.config/vibe-mac/aliases.zsh"
  : >"$VIBE_MAC_EVENT_LOG"

  run /usr/bin/env \
    HOME="$HOME" VIBE_MAC_EVENT_LOG="$VIBE_MAC_EVENT_LOG" \
    /bin/zsh -f -c 'source "$HOME/.zprofile"; source "$HOME/.zshrc"'

  [ "$status" -eq 0 ]
  assert_no_events
}

@test "generated shell resolver допускает internal Homebrew Cellar symlinks" {
  local cellar command_name fzf_cellar trusted_log
  cellar="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/tools/1/bin"
  fzf_cellar="$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/Cellar/fzf/1/shell"
  trusted_log="$TEST_ROOT/internal-cellar.log"
  export trusted_log
  mkdir -p "$cellar" "$fzf_cellar"
  for command_name in brew mise zoxide starship; do
    printf '%s\n' \
      '#!/bin/sh' \
      'printf "trusted:%s\n" "${0##*/}" >>"$trusted_log"' \
      'printf "%s\n" :' >"$cellar/$command_name"
    chmod 0755 "$cellar/$command_name"
    /bin/ln -s "../Cellar/tools/1/bin/$command_name" \
      "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/bin/$command_name"
  done
  printf '%s\n' \
    'printf "%s\n" trusted:fzf-completion >>"$trusted_log"' \
    >"$fzf_cellar/completion.zsh"
  printf '%s\n' \
    'printf "%s\n" trusted:fzf-key-bindings >>"$trusted_log"' \
    >"$fzf_cellar/key-bindings.zsh"
  /usr/bin/find \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/opt/fzf" -depth -delete
  /bin/ln -s ../Cellar/fzf/1 \
    "$VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX/opt/fzf"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  : >"$trusted_log"

  run /usr/bin/env HOME="$HOME" /bin/zsh -f -c \
    'source "$HOME/.zprofile"; source "$HOME/.zshrc"'

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc trusted:brew "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:mise "$trusted_log")" -eq 2 ]
  [ "$(grep -Fxc trusted:zoxide "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:starship "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:fzf-completion "$trusted_log")" -eq 1 ]
  [ "$(grep -Fxc trusted:fzf-key-bindings "$trusted_log")" -eq 1 ]
}

@test "canonical zshrc выносит Oh My Zsh mutable dirs и отключает update" {
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  [ "$status" -eq 0 ]
  grep -Fqx 'ZSH_CUSTOM="$HOME/.config/oh-my-zsh/custom"' "$HOME/.zshrc"
  grep -Fqx 'ZSH_CACHE_DIR="$HOME/.cache/oh-my-zsh"' "$HOME/.zshrc"
  grep -Fqx 'zstyle :omz:update mode disabled' "$HOME/.zshrc"
}

@test "shell config выбирает literal arm64 Homebrew prefix" {
  unset VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX
  export VIBE_MAC_TEST_ARCH=arm64

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  grep -Fqx "_vibe_mac_homebrew_prefix='/opt/homebrew'" "$HOME/.zprofile"
  grep -Fqx "_vibe_mac_homebrew_prefix='/opt/homebrew'" "$HOME/.zshrc"
}

@test "shell config выбирает literal unsupported Intel Homebrew prefix" {
  unset VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX
  export VIBE_MAC_TEST_ARCH=x86_64
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  grep -Fqx "_vibe_mac_homebrew_prefix='/usr/local'" "$HOME/.zprofile"
  grep -Fqx "_vibe_mac_homebrew_prefix='/usr/local'" "$HOME/.zshrc"
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
    run "$VIBE_MAC_PLUTIL_BIN" \
      -extract "$key" json -o - -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"owned":true'* ]]
    [[ "$output" == *'"applied_sha":"'* ]]
    [[ "$output" == *'"backup":{'* ]]
  done
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract components.oh_my_zsh json -o - -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"owned":true'* ]]
  [[ "$output" == *'"tree_sha256":"'* ]]
}

@test "shell upgrade обновляет owned block proof и manifest atomically" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  prefix_a="$TEST_ROOT/homebrew-a"
  prefix_b="$TEST_ROOT/homebrew-b"
  mkdir -p "$prefix_a/bin" "$prefix_b/bin"
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$prefix_a"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  old_sha="$("$VIBE_MAC_PLUTIL_BIN" \
    -extract files.zprofile.applied_sha raw -- "$VIBE_MAC_MANIFEST_FILE")"

  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$prefix_b"
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]

  actual_sha="$(/usr/bin/awk '
    $0 == "# >>> vibe-mac managed:zprofile >>>" { inside = 1; next }
    $0 == "# <<< vibe-mac managed:zprofile <<<" { inside = 0; next }
    inside { print }
  ' "$HOME/.zprofile" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  manifest_sha="$("$VIBE_MAC_PLUTIL_BIN" \
    -extract files.zprofile.applied_sha raw -- "$VIBE_MAC_MANIFEST_FILE")"
  proof_sha="$(cat \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/zprofile.created-block-sha256")"
  [ "$manifest_sha" != "$old_sha" ]
  [ "$manifest_sha" = "$actual_sha" ]
  [ "$proof_sha" = "$actual_sha" ]
  grep -Fqx "_vibe_mac_homebrew_prefix='$prefix_b'" "$HOME/.zprofile"
}

@test "shell upgrade не перезаписывает изменённый owned block" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  prefix_a="$TEST_ROOT/homebrew-a"
  prefix_b="$TEST_ROOT/homebrew-b"
  mkdir -p "$prefix_a/bin" "$prefix_b/bin"
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$prefix_a"
  /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  sed -i.bak \
    "s#_vibe_mac_homebrew_prefix='$prefix_a'#_vibe_mac_homebrew_prefix='/user/custom'#" \
    "$HOME/.zprofile"
  /bin/unlink "$HOME/.zprofile.bak"
  before="$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')"
  export VIBE_MAC_TEST_EXPECTED_HOMEBREW_PREFIX="$prefix_b"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  [ "$status" -ne 0 ]
  [ "$before" = "$(shasum -a 256 "$HOME/.zprofile" | awk '{print $1}')" ]
}

@test "shell upgrade обновляет только неизменённые owned aliases и Starship" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  release_v2="$TEST_ROOT/release-v2"
  /bin/cp -R "$PROJECT_ROOT" "$release_v2"
  printf '%s\n' '# release-v2' >>"$release_v2/config/aliases.zsh"
  printf '%s\n' '# release-v2' >>"$release_v2/config/starship.toml"

  run /usr/bin/env VIBE_MAC_ROOT="$release_v2" \
    /bin/bash "$release_v2/steps/40-shell.sh" apply

  [ "$status" -eq 0 ]
  /usr/bin/cmp -s \
    "$release_v2/config/aliases.zsh" "$HOME/.config/vibe-mac/aliases.zsh"
  /usr/bin/cmp -s \
    "$release_v2/config/starship.toml" "$HOME/.config/starship.toml"
  for id in aliases starship; do
    target="$HOME/.config/vibe-mac/aliases.zsh"
    [ "$id" = starship ] && target="$HOME/.config/starship.toml"
    manifest_sha="$("$VIBE_MAC_PLUTIL_BIN" \
      -extract "files.$id.applied_sha" raw -- "$VIBE_MAC_MANIFEST_FILE")"
    [ "$manifest_sha" = "$(shasum -a 256 "$target" | awk '{print $1}')" ]
  done
}

@test "shell verify отвергает tamper exact Ghostty block" {
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  ghostty="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  sed -i.bak 's/font-size = 14/font-size = 99/' "$ghostty"
  /bin/unlink "$ghostty.bak"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" verify

  [ "$status" -ne 0 ]
}

@test "shell verify отвергает tamper owned aliases и Oh My Zsh" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply

  printf '%s\n' 'echo aliases-tampered' >>"$HOME/.config/vibe-mac/aliases.zsh"
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" verify
  [ "$status" -ne 0 ]

  /bin/cp "$PROJECT_ROOT/config/aliases.zsh" \
    "$HOME/.config/vibe-mac/aliases.zsh"
  printf '%s\n' 'echo omz-tampered' >>"$HOME/.oh-my-zsh/oh-my-zsh.sh"
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" verify
  [ "$status" -ne 0 ]
}

@test "shell verify отвергает tamper owned Starship template" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  printf '%s\n' '# starship-tampered' >>"$HOME/.config/starship.toml"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" verify

  [ "$status" -ne 0 ]
}

@test "shell reconcile сохраняет ownership после сбоя между mutation и manifest" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_SHELL_MUTATIONS=1

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 91 ]
  [ -f "$HOME/.zshrc" ]
  [ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]

  export VIBE_MAC_TEST_CRASH_AFTER_SHELL_MUTATIONS=0
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]

  for key in files.zprofile files.zshrc files.ghostty files.aliases files.starship; do
    run "$VIBE_MAC_PLUTIL_BIN" -extract "$key.owned" raw -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
  done
  run "$VIBE_MAC_PLUTIL_BIN" -extract components.oh_my_zsh.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "zprofile после crash before block mutation и ручного exact block остаётся unowned" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_BLOCK_EVIDENCE=zprofile

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 94 ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/zprofile.absent" ]
  assert_path_absent "$HOME/.zprofile"
  assert_path_absent \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/zprofile.created-block-sha256"

  render_home="$TEST_ROOT/render-home"
  render_backup="$render_home/.vibe-mac-backup"
  render_runtime="$render_home/.vibe-mac"
  render_tmp="$TEST_ROOT/render-tmp"
  render_events="$TEST_ROOT/render-events.log"
  mkdir -p "$render_home" "$render_tmp"
  : >"$render_events"
  run /usr/bin/env \
    HOME="$render_home" \
    VIBE_MAC_BACKUP_ROOT="$render_backup" \
    VIBE_MAC_RUNTIME_ROOT="$render_runtime" \
    VIBE_MAC_STATE_DIR="$render_runtime/state" \
    VIBE_MAC_MANIFEST_FILE="$render_runtime/state/missing-manifest.json" \
    VIBE_MAC_INSTALL_ID=render \
    VIBE_MAC_EVENT_LOG="$render_events" \
    TMPDIR="$render_tmp" \
    VIBE_MAC_TEST_CRASH_AFTER_BLOCK_EVIDENCE= \
    /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  cp "$render_home/.zprofile" "$HOME/.zprofile"

  unset VIBE_MAC_TEST_CRASH_AFTER_BLOCK_EVIDENCE
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.zprofile.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.zprofile.preexisting raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  assert_path_absent \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/zprofile.created-block-sha256"
}

@test "shell reconcile не присваивает ownership ручному Oh My Zsh после сбоя до mutation" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_OMZ_EVIDENCE=1

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 92 ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/oh-my-zsh.absent" ]
  assert_path_absent "$HOME/.oh-my-zsh"

  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' '# test Oh My Zsh' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
  export VIBE_MAC_TEST_CRASH_AFTER_OMZ_EVIDENCE=0

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract components.oh_my_zsh.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract components.oh_my_zsh.preexisting raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "aliases после crash before mutation и ручного создания остаётся unowned" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_FILE_EVIDENCE=aliases-zsh

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 93 ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/aliases-zsh.absent" ]
  assert_path_absent "$HOME/.config/vibe-mac/aliases.zsh"
  assert_path_absent \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/aliases-zsh.created-file-sha256"

  cp "$PROJECT_ROOT/config/aliases.zsh" "$HOME/.config/vibe-mac/aliases.zsh"
  unset VIBE_MAC_TEST_CRASH_AFTER_FILE_EVIDENCE
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.aliases.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.aliases.preexisting raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  assert_path_absent \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/aliases-zsh.created-file-sha256"
}

@test "absent evidence без creation proof не присваивает ownership ручным shell files" {
  mkdir -p "$HOME/.config/vibe-mac"
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
    backup_file_once "$HOME/.config/vibe-mac/aliases.zsh" aliases-zsh >/dev/null
    backup_file_once "$HOME/.config/starship.toml" starship-toml >/dev/null
  '
  cp "$PROJECT_ROOT/config/aliases.zsh" "$HOME/.config/vibe-mac/aliases.zsh"
  cp "$PROJECT_ROOT/config/starship.toml" "$HOME/.config/starship.toml"

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]

  for id in aliases starship; do
    run "$VIBE_MAC_PLUTIL_BIN" \
      -extract "files.$id.owned" raw -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
    run "$VIBE_MAC_PLUTIL_BIN" \
      -extract "files.$id.preexisting" raw -- "$VIBE_MAC_MANIFEST_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
  done
}

@test "starship config после crash before mutation и ручного создания остаётся unowned" {
  /bin/bash -c '
    source "$PROJECT_ROOT/config/versions.env"
    source "$PROJECT_ROOT/lib/util.sh"
    manifest_init "$PROJECT_ROOT/state/manifest-template.json" "$VIBE_MAC_MANIFEST_FILE"
  '
  export VIBE_MAC_TEST_CRASH_AFTER_FILE_EVIDENCE=starship-toml

  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 93 ]
  [ -f "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/starship-toml.absent" ]
  assert_path_absent "$HOME/.config/starship.toml"
  assert_path_absent \
    "$VIBE_MAC_BACKUP_ROOT/$VIBE_MAC_INSTALL_ID/starship-toml.created-file-sha256"

  cp "$PROJECT_ROOT/config/starship.toml" "$HOME/.config/starship.toml"
  unset VIBE_MAC_TEST_CRASH_AFTER_FILE_EVIDENCE
  run /bin/bash "$PROJECT_ROOT/steps/40-shell.sh" apply
  [ "$status" -eq 0 ]

  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.starship.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.starship.preexisting raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  run "$VIBE_MAC_PLUTIL_BIN" \
    -extract files.aliases.owned raw -- "$VIBE_MAC_MANIFEST_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}
