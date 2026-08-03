#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(/bin/realpath "$0" 2>/dev/null)" || {
  /usr/bin/printf '%s\n' 'Ошибка: install.sh path нельзя канонизировать.' >&2
  exit 2
}
case "$SCRIPT_PATH" in
  /*/*) SCRIPT_DIR="${SCRIPT_PATH%/*}" ;;
  *)
    /usr/bin/printf '%s\n' 'Ошибка: install.sh path небезопасен.' >&2
    exit 2
    ;;
esac
VIBE_MAC_ROOT="$SCRIPT_DIR"
export VIBE_MAC_ROOT

# `git archive` replaces this literal with the exact release commit. Source
# checkouts retain test seams; packaged entrypoints force production paths and
# verify the active release before sourcing any release-controlled file.
# shellcheck disable=SC2016
VIBE_MAC_INSTALL_BUILD_COMMIT='$Format:%H$'
# shellcheck disable=SC2016
VIBE_MAC_INSTALL_SOURCE_MARKER='$''Format:%H$'
case "$VIBE_MAC_INSTALL_BUILD_COMMIT" in
  "$VIBE_MAC_INSTALL_SOURCE_MARKER")
    VIBE_MAC_INSTALL_BUILD_KIND=source
    ;;
  *)
    if [ "${#VIBE_MAC_INSTALL_BUILD_COMMIT}" -ne 40 ] ||
      ! printf '%s\n' "$VIBE_MAC_INSTALL_BUILD_COMMIT" |
      LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{40}$'; then
      printf '%s\n' 'Ошибка: неизвестный build marker install.sh.' >&2
      exit 2
    fi
    VIBE_MAC_INSTALL_BUILD_KIND=release
    VIBE_MAC_TEST_MODE=0
    export VIBE_MAC_TEST_MODE
    ;;
esac
readonly VIBE_MAC_INSTALL_BUILD_COMMIT VIBE_MAC_INSTALL_SOURCE_MARKER
readonly VIBE_MAC_INSTALL_BUILD_KIND

install_entrypoint_integrity_fail() {
  printf 'Ошибка: active release vibe-mac повреждён: %s\n' "$1" >&2
  exit 2
}

install_entrypoint_file_mode() {
  if /usr/bin/stat -f '%Lp' "$1" >/dev/null 2>&1; then
    /usr/bin/stat -f '%Lp' "$1"
  else
    /usr/bin/stat -c '%a' "$1"
  fi
}

install_entrypoint_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

install_entrypoint_sha256_stdin() {
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

install_entrypoint_sha_marker() {
  local marker value
  marker="$1"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  value="$(/bin/cat "$marker")" || return 2
  [ "${#value}" -eq 64 ] || return 2
  case "$value" in *[!0-9a-f]*) return 2 ;; esac
  printf '%s\n' "$value"
}

install_entrypoint_release_tree_sha256() {
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
          mode="$(install_entrypoint_file_mode "$absolute")" || exit 2
          file_sha="$(install_entrypoint_sha256_file "$absolute")" || exit 2
          printf 'F\t%s\t%s\t%s\n' \
            "$mode" "$file_sha" "$path"
        elif [ -d "$absolute" ]; then
          mode="$(install_entrypoint_file_mode "$absolute")" || exit 2
          printf 'D\t%s\t-\t%s\n' "$mode" "$path"
        else
          exit 2
        fi
      done |
      install_entrypoint_sha256_stdin
}

install_entrypoint_verify_active_release() {
  local home_physical runtime releases current target version release
  local runtime_physical releases_physical release_physical
  local archive_sha expected_tree actual_tree control_status

  case "${HOME:-}" in
    /*) ;;
    *) install_entrypoint_integrity_fail 'HOME должен быть absolute path.' ;;
  esac
  control_status=0
  printf '%s' "$HOME" |
    LC_ALL=C /usr/bin/grep -Eq '[[:cntrl:]]' || control_status="$?"
  case "$control_status" in
    0)
      install_entrypoint_integrity_fail 'HOME содержит control character.'
      ;;
    1) ;;
    *) install_entrypoint_integrity_fail 'HOME нельзя проверить.' ;;
  esac
  [ -d "$HOME" ] && [ ! -L "$HOME" ] ||
    install_entrypoint_integrity_fail 'HOME отсутствует или является symlink.'
  home_physical="$(/bin/realpath "$HOME" 2>/dev/null)" ||
    install_entrypoint_integrity_fail 'HOME нельзя канонизировать.'
  [ "$HOME" = "$home_physical" ] ||
    install_entrypoint_integrity_fail 'HOME содержит symlink или dot segment.'

  runtime="$HOME/.vibe-mac"
  releases="$runtime/releases"
  current="$runtime/current"
  [ -d "$runtime" ] && [ ! -L "$runtime" ] ||
    install_entrypoint_integrity_fail 'runtime root небезопасен.'
  runtime_physical="$(/bin/realpath "$runtime" 2>/dev/null)" ||
    install_entrypoint_integrity_fail 'runtime root нельзя канонизировать.'
  [ "$runtime_physical" = "$home_physical/.vibe-mac" ] ||
    install_entrypoint_integrity_fail 'runtime root вышел за HOME.'
  [ -d "$releases" ] && [ ! -L "$releases" ] ||
    install_entrypoint_integrity_fail 'releases небезопасен.'
  releases_physical="$(/bin/realpath "$releases" 2>/dev/null)" ||
    install_entrypoint_integrity_fail 'releases нельзя канонизировать.'
  [ "$releases_physical" = "$runtime_physical/releases" ] ||
    install_entrypoint_integrity_fail 'releases вышел за runtime root.'

  [ -L "$current" ] ||
    install_entrypoint_integrity_fail 'current должен быть symlink.'
  target="$(/usr/bin/readlink "$current")" ||
    install_entrypoint_integrity_fail 'current не читается.'
  case "$target" in
    releases/[A-Za-z0-9]*)
      version="${target#releases/}"
      case "$version" in
        *[!A-Za-z0-9._-]*|*..*)
          install_entrypoint_integrity_fail \
            'current содержит небезопасную версию.'
          ;;
      esac
      ;;
    *)
      install_entrypoint_integrity_fail \
        'current должен указывать на releases/<version>.'
      ;;
  esac
  [ "$target" = "releases/$version" ] ||
    install_entrypoint_integrity_fail 'current содержит extra path.'

  release="$runtime/$target"
  [ -d "$release" ] && [ ! -L "$release" ] ||
    install_entrypoint_integrity_fail 'active release небезопасен.'
  release_physical="$(/bin/realpath "$release" 2>/dev/null)" ||
    install_entrypoint_integrity_fail 'active release нельзя канонизировать.'
  [ "$release_physical" = "$releases_physical/$version" ] ||
    install_entrypoint_integrity_fail 'active release вышел за releases.'
  [ "$SCRIPT_DIR" = "$release_physical" ] ||
    install_entrypoint_integrity_fail \
      'install.sh запущен не из active release.'

  archive_sha="$(install_entrypoint_sha_marker \
    "$release/.bundle-sha256")" ||
    install_entrypoint_integrity_fail '.bundle-sha256 malformed.'
  [ -n "$archive_sha" ] ||
    install_entrypoint_integrity_fail '.bundle-sha256 пуст.'
  expected_tree="$(install_entrypoint_sha_marker \
    "$release/.bundle-tree-sha256")" ||
    install_entrypoint_integrity_fail '.bundle-tree-sha256 malformed.'
  actual_tree="$(install_entrypoint_release_tree_sha256 "$release")" ||
    install_entrypoint_integrity_fail 'release tree небезопасен.'
  [ "$actual_tree" = "$expected_tree" ] ||
    install_entrypoint_integrity_fail 'release tree fingerprint не совпал.'
}

if [ "$VIBE_MAC_INSTALL_BUILD_KIND" = release ]; then
  install_entrypoint_verify_active_release
fi

# shellcheck source=config/versions.env
source "$VIBE_MAC_ROOT/config/versions.env"
# shellcheck source=lib/util.sh
source "$VIBE_MAC_ROOT/lib/util.sh"
# shellcheck source=lib/ui.sh
source "$VIBE_MAC_ROOT/lib/ui.sh"
# shellcheck source=lib/guard.sh
source "$VIBE_MAC_ROOT/lib/guard.sh"

DRY_RUN="${DRY_RUN:-0}"
EXTRAS="${EXTRAS:-0}"
SKIP_DEFAULTS="${SKIP_DEFAULTS:-0}"
ALLOW_UNSUPPORTED_INTEL="${ALLOW_UNSUPPORTED_INTEL:-0}"
# Full verification is an internal channel used only by verify.sh. A caller
# cannot turn DRY_RUN into executable package/CLI probes.
VIBE_MAC_FULL_VERIFY=0
export DRY_RUN EXTRAS SKIP_DEFAULTS ALLOW_UNSUPPORTED_INTEL
export VIBE_MAC_FULL_VERIFY

STATE_TEMPLATE="$VIBE_MAC_ROOT/state/progress-template.json"
MANIFEST_TEMPLATE="$VIBE_MAC_ROOT/state/manifest-template.json"
export STATE_TEMPLATE MANIFEST_TEMPLATE

if is_test_mode && [ -n "${VIBE_MAC_STEPS_DIR:-}" ]; then
  STEPS_DIR="$VIBE_MAC_STEPS_DIR"
else
  STEPS_DIR="$VIBE_MAC_ROOT/steps"
fi

if is_test_mode && [ -n "${VIBE_MAC_STEP_IDS:-}" ]; then
  STEP_IDS="$VIBE_MAC_STEP_IDS"
else
  STEP_IDS="00-preflight 10-xcode-clt 20-homebrew 30-brew-bundle 40-shell 50-runtimes 60-ai-agents 70-git-github 80-defaults 90-workspace"
fi

LOCK_HELD=0
CURRENT_STEP=bootstrap
INSTALL_MANIFEST_NEEDS_FRESH_INIT=0

usage() {
  printf '%s\n' \
    "vibe-mac $VIBE_MAC_VERSION" \
    "Запуск: /bin/bash ./install.sh" \
    "Флаги окружения: DRY_RUN=1 EXTRAS=1 SKIP_DEFAULTS=1 ALLOW_UNSUPPORTED_INTEL=1"
}

validate_step_id() {
  case "$1" in
    [0-9][0-9]-[A-Za-z0-9-]*)
      return 0
      ;;
    *)
      ui_fail "Некорректный ID шага: $1."
      return 2
      ;;
  esac
}

step_file() {
  local step file
  step="$1"
  validate_step_id "$step"
  file="$STEPS_DIR/$step.sh"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    ui_fail "Не найден безопасный файл шага: $file."
    return 2
  fi
  printf '%s\n' "$file"
}

run_step() {
  local step action file
  step="$1"
  action="$2"
  file="$(step_file "$step")"
  /bin/bash "$file" "$action"
}

state_complete_if_known() {
  local step status
  step="$1"
  if state_has_step "$VIBE_MAC_STATE_FILE" "$step"; then
    status="$(state_get_status "$VIBE_MAC_STATE_FILE" "$step")"
    if [ "$status" != "completed" ]; then
      state_mark_complete "$VIBE_MAC_STATE_FILE" "$step" "$(utc_now)"
    fi
  elif ! is_test_mode; then
    ui_fail "Шаг отсутствует в progress schema: $step."
    return 2
  fi
}

state_step_completed() {
  local step
  step="$1"
  state_has_step "$VIBE_MAC_STATE_FILE" "$step" &&
    [ "$(state_get_status "$VIBE_MAC_STATE_FILE" "$step")" = "completed" ]
}

directory_entries_allowed() (
  local directory entry name candidate matched
  directory="$1"
  shift
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 2
  shopt -s nullglob dotglob
  for entry in "$directory"/*; do
    name="${entry##*/}"
    matched=0
    for candidate in "$@"; do
      if [ "$name" = "$candidate" ]; then
        matched=1
        break
      fi
    done
    [ "$matched" = 1 ] || return 1
  done
)

directory_is_empty() {
  directory_entries_allowed "$1"
}

fresh_bootstrap_release_ready() {
  local version archive_sha tree_sha expected_root current_target actual_tree
  local launcher launcher_sha
  version="${VIBE_MAC_RELEASE_VERSION:-}"
  archive_sha="${VIBE_MAC_RELEASE_ARCHIVE_SHA256:-}"
  tree_sha="${VIBE_MAC_RELEASE_TREE_SHA256:-}"
  if [ "$VIBE_MAC_BUILD_KIND" != release ]; then
    is_test_mode && [ "${VIBE_MAC_TEST_ALLOW_FRESH_RELEASE:-0}" = 1 ] ||
      return 1
  fi
  case "$version" in
    [A-Za-z0-9]*)
      case "$version" in *[!A-Za-z0-9._-]*|*..*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  validate_sha256_or_empty "$archive_sha" && [ -n "$archive_sha" ] ||
    return 2
  validate_sha256_or_empty "$tree_sha" && [ -n "$tree_sha" ] || return 2

  expected_root="$VIBE_MAC_RUNTIME_ROOT/releases/$version"
  [ "$VIBE_MAC_ROOT" = "$expected_root" ] || return 2
  [ -d "$expected_root" ] && [ ! -L "$expected_root" ] || return 2
  [ -f "$expected_root/.bundle-sha256" ] &&
    [ ! -L "$expected_root/.bundle-sha256" ] || return 2
  [ -f "$expected_root/.bundle-tree-sha256" ] &&
    [ ! -L "$expected_root/.bundle-tree-sha256" ] || return 2
  [ "$(/bin/cat "$expected_root/.bundle-sha256")" = "$archive_sha" ] ||
    return 2
  [ "$(/bin/cat "$expected_root/.bundle-tree-sha256")" = "$tree_sha" ] ||
    return 2
  actual_tree="$(release_tree_sha256 "$expected_root")" || return 2
  [ "$actual_tree" = "$tree_sha" ] || return 2

  [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ] || return 2
  current_target="$(/usr/bin/readlink "$VIBE_MAC_RUNTIME_ROOT/current")" ||
    return 2
  [ "$current_target" = "releases/$version" ] || return 2
  directory_entries_allowed "$VIBE_MAC_RUNTIME_ROOT/releases" "$version" ||
    return 2
  directory_entries_allowed "$VIBE_MAC_RUNTIME_ROOT/bin" \
    vibe-mac-verify vibe-mac-doctor vibe-mac-uninstall || return 2

  for launcher in verify doctor uninstall; do
    case "$launcher" in
      verify) launcher_sha="${VIBE_MAC_LAUNCHER_VERIFY_SHA256:-}" ;;
      doctor) launcher_sha="${VIBE_MAC_LAUNCHER_DOCTOR_SHA256:-}" ;;
      uninstall) launcher_sha="${VIBE_MAC_LAUNCHER_UNINSTALL_SHA256:-}" ;;
    esac
    validate_sha256_or_empty "$launcher_sha" && [ -n "$launcher_sha" ] ||
      return 2
    [ -f "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher" ] &&
      [ ! -L "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher" ] || return 2
    [ "$(sha256_file "$VIBE_MAC_RUNTIME_ROOT/bin/vibe-mac-$launcher")" = \
      "$launcher_sha" ] || return 2
  done
}

fresh_runtime_layout_ready() {
  local runtime_has_release
  directory_entries_allowed "$VIBE_MAC_RUNTIME_ROOT" \
    releases bin state logs current || return 2
  directory_entries_allowed "$VIBE_MAC_STATE_DIR" \
    progress.json manifest.json install.lock.d || return 2
  directory_is_empty "$VIBE_MAC_LOG_DIR" || return 2

  runtime_has_release=0
  if [ -e "$VIBE_MAC_RUNTIME_ROOT/current" ] ||
    [ -L "$VIBE_MAC_RUNTIME_ROOT/current" ] ||
    ! directory_is_empty "$VIBE_MAC_RUNTIME_ROOT/releases" ||
    ! directory_is_empty "$VIBE_MAC_RUNTIME_ROOT/bin"; then
    runtime_has_release=1
  fi
  if [ "$runtime_has_release" = 1 ]; then
    fresh_bootstrap_release_ready || return 2
  fi
}

managed_marker_absent() {
  local target marker status
  target="$1"
  marker="$2"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  [ -f "$target" ] && [ ! -L "$target" ] || return 0
  status=0
  /usr/bin/grep -Fq "$marker" "$target" || status="$?"
  case "$status" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

missing_manifest_state_is_fresh() {
  if [ -e "$VIBE_MAC_STATE_FILE" ] || [ -L "$VIBE_MAC_STATE_FILE" ]; then
    [ -f "$VIBE_MAC_STATE_FILE" ] && [ ! -L "$VIBE_MAC_STATE_FILE" ] ||
      return 2
    /usr/bin/cmp -s "$STATE_TEMPLATE" "$VIBE_MAC_STATE_FILE" || return 2
  fi

  if [ -e "$VIBE_MAC_BACKUP_ROOT" ] || [ -L "$VIBE_MAC_BACKUP_ROOT" ]; then
    return 2
  fi
  fresh_runtime_layout_ready || return 2
  if [ -e "$HOME/.config/vibe-mac/aliases.zsh" ] ||
    [ -L "$HOME/.config/vibe-mac/aliases.zsh" ]; then
    return 2
  fi
  managed_marker_absent \
    "$HOME/.zprofile" '# >>> vibe-mac managed:zprofile >>>' || return 2
  managed_marker_absent \
    "$HOME/.zshrc" '# >>> vibe-mac managed:zshrc >>>' || return 2
  managed_marker_absent \
    "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
    '# >>> vibe-mac managed:ghostty >>>' || return 2
}

install_metadata_preflight() {
  local schema install_id
  INSTALL_MANIFEST_NEEDS_FRESH_INIT=0
  if [ -e "$VIBE_MAC_MANIFEST_FILE" ] || [ -L "$VIBE_MAC_MANIFEST_FILE" ]; then
    if [ -L "$VIBE_MAC_MANIFEST_FILE" ] ||
      [ ! -f "$VIBE_MAC_MANIFEST_FILE" ] ||
      ! json_lint "$VIBE_MAC_MANIFEST_FILE"; then
      ui_fail "manifest.json повреждён или является symlink."
      return 2
    fi
    schema="$(json_extract_raw "$VIBE_MAC_MANIFEST_FILE" schema_version)" ||
      return 2
    if [ "$schema" != "${MANIFEST_SCHEMA_VERSION:-1}" ]; then
      ui_fail "Неизвестная версия manifest schema: $schema."
      return 2
    fi
    install_id="$(json_extract_raw "$VIBE_MAC_MANIFEST_FILE" install_id)" ||
      return 2
    if [ -z "$install_id" ]; then
      INSTALL_MANIFEST_NEEDS_FRESH_INIT=1
    fi
  else
    INSTALL_MANIFEST_NEEDS_FRESH_INIT=1
  fi

  if [ -e "$VIBE_MAC_STATE_FILE" ] || [ -L "$VIBE_MAC_STATE_FILE" ]; then
    state_init "$STATE_TEMPLATE" "$VIBE_MAC_STATE_FILE" || return "$?"
  fi
  if [ "$INSTALL_MANIFEST_NEEDS_FRESH_INIT" = 1 ] &&
    ! missing_manifest_state_is_fresh; then
    ui_fail "Нельзя создать новый manifest: найдено состояние прошлой установки."
    return 2
  fi
}

step_needs_first_apply() {
  case "$1" in
    30-brew-bundle|40-shell|50-runtimes|60-ai-agents|70-git-github|80-defaults|90-workspace)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

cleanup() {
  local exit_code
  exit_code="$?"
  if [ "$LOCK_HELD" = "1" ]; then
    release_lock || true
    LOCK_HELD=0
  fi
  if [ "$exit_code" -ne 0 ]; then
    if [ -n "$VIBE_MAC_LOG_FILE" ]; then
      ui_fail "Остановились на шаге $CURRENT_STEP. Лог: $VIBE_MAC_LOG_FILE"
    else
      ui_fail "Остановились до создания лога."
    fi
  fi
  return "$exit_code"
}

run_dry_plan() {
  local step verify_status
  ui_info "DRY_RUN: только читаю состояние; сеть, записи, sudo и GUI запрещены."
  for step in $STEP_IDS; do
    CURRENT_STEP="$step"
    verify_status=0
    run_step "$step" verify >/dev/null 2>&1 || verify_status="$?"
    case "$verify_status" in
      0)
        ui_status "Уже стоит" "$step"
        ;;
      1)
        run_step "$step" plan
        ui_status "Пропущено" "DRY_RUN: $step"
        ;;
      *)
        ui_fail "Integrity-проверка шага $step завершилась с кодом $verify_status."
        return 2
        ;;
    esac
  done
  ui_info "DRY_RUN завершён без изменений."
}

run_install() {
  local step verified verify_status apply_status

  init_runtime_layout
  acquire_lock
  LOCK_HELD=1
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  install_metadata_preflight
  state_init "$STATE_TEMPLATE" "$VIBE_MAC_STATE_FILE"
  manifest_init "$MANIFEST_TEMPLATE" "$VIBE_MAC_MANIFEST_FILE"
  if [ -z "$(json_extract_raw \
    "$VIBE_MAC_MANIFEST_FILE" platform.architecture 2>/dev/null || true)" ]; then
    manifest_record_platform \
      "$(guard_architecture)" \
      "$(guard_macos_version)"
  fi
  manifest_record_release_from_env
  init_log
  log_event info bootstrap "Начат vibe-mac $VIBE_MAC_VERSION."

  for step in $STEP_IDS; do
    CURRENT_STEP="$step"
    log_event info "$step" "Проверка шага."

    verified=0
    verify_status=0
    run_step "$step" verify >/dev/null 2>&1 || verify_status="$?"
    case "$verify_status" in
      0) verified=1 ;;
      1) ;;
      *)
        log_event error "$step" \
          "Integrity-проверка завершилась с кодом $verify_status."
        ui_status "Ошибка" "$step: integrity"
        return 2
        ;;
    esac

    if [ "$verified" = "1" ] &&
      { state_step_completed "$step" || ! step_needs_first_apply "$step"; }; then
      state_complete_if_known "$step"
      ui_status "Уже стоит" "$step"
      log_event success "$step" "Уже стоит."
      continue
    fi

    run_step "$step" plan
    apply_status=0
    run_step "$step" apply || apply_status="$?"
    case "$apply_status" in
      0) ;;
      1)
        log_event error "$step" "Apply завершился ошибкой."
        ui_status "Ошибка" "$step"
        return 1
        ;;
      *)
        log_event error "$step" \
          "Apply завершился integrity-кодом $apply_status."
        ui_status "Ошибка" "$step: integrity"
        return 2
        ;;
    esac

    verify_status=0
    run_step "$step" verify >/dev/null 2>&1 || verify_status="$?"
    case "$verify_status" in
      0) ;;
      1)
        log_event error "$step" "Проверка после apply не прошла."
        ui_status "Ошибка" "$step"
        return 1
        ;;
      *)
        log_event error "$step" \
          "Integrity-проверка после apply завершилась с кодом $verify_status."
        ui_status "Ошибка" "$step: integrity"
        return 2
        ;;
    esac

    state_complete_if_known "$step"
    ui_status "Установлено" "$step"
    log_event success "$step" "Установлено."
  done

  CURRENT_STEP=complete
  log_event success complete "Техническая установка завершена."
  ui_info "Техническая установка завершена."
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --version)
    printf '%s\n' "$VIBE_MAC_VERSION"
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

guard_preflight

if [ "$DRY_RUN" = "1" ]; then
  run_dry_plan
else
  if [ "$(guard_architecture)" = x86_64 ]; then
    DRY_RUN=1
    export DRY_RUN
    run_dry_plan
    DRY_RUN=0
    export DRY_RUN
    if ! ui_confirm_typed "Intel-режим не поддерживается; полный план выше." INTEL; then
      ui_fail "Intel-режим не подтверждён."
      exit 2
    fi
  fi
  run_install
fi
