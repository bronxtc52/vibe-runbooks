#!/usr/bin/env bash
set -euo pipefail

# Заведомо плохая fixture: нужна, чтобы доказать чувствительность tripwire.
mkdir -p "$HOME/should-never-exist-in-dry-run"
printf '%s\n' "write" >>"$VIBE_MAC_EVENT_LOG"
