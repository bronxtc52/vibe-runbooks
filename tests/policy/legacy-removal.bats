#!/usr/bin/env bats

load ../helpers/test-helper

setup() {
  vibe_test_setup
}

@test "exact legacy map удалён из рабочего дерева" {
  legacy_paths="
00-preflight
01-macbook-setup
02-foundation
03-git-github
04-ai-helpers
05-flutter
05w-netlify
06-first-win
06w-first-site
07-checkpoint
99-appendix-backend
CLAUDE.md
FOR-CODEX.md
INDEX.md
RITUALS.md
templates
scripts/askpass.sh
scripts/command-guard.py
scripts/lib.sh
tests/checkpoint-handoff.bats
tests/command-guard.bats
tests/lib.bats
tests/routing.bats
tests/secret-regex.bats
"
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ ! -e "$PROJECT_ROOT/$path" ]
    [ ! -L "$PROJECT_ROOT/$path" ]
  done <<<"$legacy_paths"
}

@test "публичные документы не ведут по старому учебному маршруту" {
  run rg -n -i \
    'flutter|android|cocoapods|netlify|railway|mobile track|мобильный трек|веб-трек|фаза 0|07-checkpoint' \
    "$PROJECT_ROOT/README.md" \
    "$PROJECT_ROOT/AGENTS.md" \
    "$PROJECT_ROOT/TROUBLESHOOTING.md"

  [ "$status" -eq 1 ]
}
