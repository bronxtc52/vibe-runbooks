#!/usr/bin/env bash

make_fake_command() {
  local name body fake_dir
  name="$1"
  body="$2"
  fake_dir="$TEST_ROOT/fake-bin"
  mkdir -p "$fake_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' "$body"
  } >"$fake_dir/$name"
  chmod +x "$fake_dir/$name"
  PATH="$fake_dir:$PATH"
  export PATH
}

make_recording_command() {
  local name exit_code
  name="$1"
  exit_code="$2"
  # shellcheck disable=SC2016
  make_fake_command "$name" \
    'printf "%s\n" "'"$name"' $*" >>"$VIBE_MAC_EVENT_LOG"; exit '"$exit_code"
}
