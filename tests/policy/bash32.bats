#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
}

@test "production shell-код совместим с системным Bash 3.2" {
  run /bin/bash -c '
    files="$PROJECT_ROOT/bootstrap.sh $PROJECT_ROOT/install.sh $PROJECT_ROOT/verify.sh $PROJECT_ROOT/doctor.sh $PROJECT_ROOT/uninstall.sh"
    for file in $PROJECT_ROOT/lib/*.sh $PROJECT_ROOT/steps/*.sh $PROJECT_ROOT/scripts/*.sh; do
      files="$files $file"
    done
    if rg -n "(^|[^[:alnum:]_])(mapfile|readarray|coproc)([[:space:]]|$)|(declare|typeset|local)[[:space:]]+-[^[:space:]]*[An]|\\$\\{[^}]+(\\^\\^?|,,?|@Q)\\}|wait[[:space:]]+-n|\\[\\[[^]]*[[:space:]]-v[[:space:]]|shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe)|[|]&|&>>|;;&|;&" $files; then
      exit 1
    fi
  '

  [ "$status" -eq 0 ]
}

@test "production shell-код использует bash и strict mode" {
  run /bin/bash -c '
    files="$PROJECT_ROOT/bootstrap.sh $PROJECT_ROOT/install.sh $PROJECT_ROOT/verify.sh $PROJECT_ROOT/doctor.sh $PROJECT_ROOT/uninstall.sh"
    for file in $PROJECT_ROOT/lib/*.sh $PROJECT_ROOT/steps/*.sh $PROJECT_ROOT/scripts/*.sh; do
      files="$files $file"
    done
    for file in $files; do
      [ "$(/usr/bin/sed -n "1p" "$file")" = "#!/usr/bin/env bash" ] || exit 1
      /usr/bin/grep -Fqx "set -euo pipefail" "$file" || exit 1
    done
  '

  [ "$status" -eq 0 ]
}
