#!/usr/bin/env bash
set -euo pipefail

guard_os_name() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_TEST_OS:-Darwin}"
  else
    /usr/bin/uname -s
  fi
}

guard_architecture() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_TEST_ARCH:-arm64}"
  else
    /usr/bin/uname -m
  fi
}

guard_macos_version() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_TEST_MACOS_VERSION:-14.0}"
  else
    /usr/bin/sw_vers -productVersion
  fi
}

guard_uid() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_TEST_UID:-501}"
  else
    /usr/bin/id -u
  fi
}

guard_free_kb() {
  if is_test_mode; then
    printf '%s\n' "${VIBE_MAC_TEST_FREE_KB:-31457280}"
  else
    /bin/df -Pk "$HOME" | /usr/bin/awk 'NR == 2 {print $4}'
  fi
}

guard_validate_flags() {
  DRY_RUN="${DRY_RUN:-0}"
  EXTRAS="${EXTRAS:-0}"
  SKIP_DEFAULTS="${SKIP_DEFAULTS:-0}"
  ALLOW_UNSUPPORTED_INTEL="${ALLOW_UNSUPPORTED_INTEL:-0}"
  validate_bool DRY_RUN "$DRY_RUN"
  validate_bool EXTRAS "$EXTRAS"
  validate_bool SKIP_DEFAULTS "$SKIP_DEFAULTS"
  validate_bool ALLOW_UNSUPPORTED_INTEL "$ALLOW_UNSUPPORTED_INTEL"
  export DRY_RUN EXTRAS SKIP_DEFAULTS ALLOW_UNSUPPORTED_INTEL
}

guard_platform() {
  local os version major arch minimum
  os="$(guard_os_name)"
  if [ "$os" != "Darwin" ]; then
    ui_fail "vibe-mac поддерживает только macOS."
    return 2
  fi

  version="$(guard_macos_version)"
  major="${version%%.*}"
  minimum="${MIN_MACOS_MAJOR:-14}"
  case "$major" in
    ''|*[!0-9]*)
      ui_fail "Не удалось определить версию macOS."
      return 2
      ;;
  esac
  if [ "$major" -lt "$minimum" ]; then
    ui_fail "Нужна macOS 14 или новее. Сейчас: macOS $version."
    return 2
  fi

  arch="$(guard_architecture)"
  case "$arch" in
    arm64)
      return 0
      ;;
    x86_64)
      if [ "$ALLOW_UNSUPPORTED_INTEL" != "1" ]; then
        ui_fail "Intel Mac не входит в поддерживаемую платформу."
        ui_info "Сначала выполни DRY_RUN=1 ALLOW_UNSUPPORTED_INTEL=1."
        return 2
      fi
      if [ "$DRY_RUN" = "1" ]; then
        ui_warn "Показан экспериментальный план для Intel; изменений не будет."
        return 0
      fi
      if ! ui_confirm_typed \
        "Intel-режим не поддерживается и может завершиться ошибкой." \
        INTEL; then
        ui_fail "Intel-режим не подтверждён."
        return 2
      fi
      ;;
    *)
      ui_fail "Неизвестная архитектура Mac: $arch."
      return 2
      ;;
  esac
}

guard_not_root() {
  local uid
  uid="$(guard_uid)"
  if [ "$uid" = "0" ]; then
    ui_fail "Не запускай vibe-mac от root или через sudo."
    return 2
  fi
}

guard_disk() {
  local free_kb required_kb required_gb
  free_kb="$(guard_free_kb)"
  required_gb="${MIN_FREE_DISK_GB:-15}"
  case "$free_kb" in
    ''|*[!0-9]*)
      ui_fail "Не удалось определить свободное место."
      return 2
      ;;
  esac
  required_kb=$((required_gb * 1024 * 1024))
  if [ "$free_kb" -lt "$required_kb" ]; then
    ui_fail "Нужно минимум $required_gb ГБ свободного места."
    return 1
  fi
}

guard_network() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if is_test_mode; then
    if [ "${VIBE_MAC_TEST_NETWORK:-ok}" = "ok" ]; then
      return 0
    fi
    ui_fail "Нет доступа к официальным источникам."
    return 1
  fi
  if ! retry /usr/bin/curl \
    --proto '=https' \
    --tlsv1.2 \
    --fail \
    --location \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time 20 \
    --output /dev/null \
    https://github.com/; then
    ui_fail "Нет доступа к GitHub. Проверь интернет и повтори запуск."
    return 1
  fi
}

guard_required_system_tools() {
  local tool
  if is_test_mode; then
    [ "${VIBE_MAC_TEST_SYSTEM_TOOLS:-ok}" = "ok" ]
    return
  fi
  for tool in /bin/bash /bin/zsh /usr/bin/curl /usr/bin/shasum \
    /usr/bin/tar /usr/bin/awk /usr/bin/sed /usr/bin/grep /usr/bin/find \
    /usr/bin/stat /bin/df /bin/mkdir /bin/mv /bin/cp /bin/chmod; do
    if [ ! -x "$tool" ]; then
      ui_fail "Не найдена системная команда: $tool."
      return 2
    fi
  done
  if [ "$DRY_RUN" != "1" ] && [ ! -x /usr/bin/sudo ]; then
    ui_fail "Не найден системный sudo."
    return 2
  fi
}

guard_preflight() {
  guard_validate_flags
  guard_not_root
  guard_platform
  guard_disk
  guard_required_system_tools
  guard_network
}

expected_homebrew_prefix() {
  case "$(guard_architecture)" in
    arm64)
      printf '%s\n' /opt/homebrew
      ;;
    x86_64)
      printf '%s\n' /usr/local
      ;;
    *)
      return 2
      ;;
  esac
}
