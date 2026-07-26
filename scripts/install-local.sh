#!/usr/bin/env bash
# Sync this working tree into the local Balatro mod folder and verify it took.
# The Balatro Multiplayer Launcher reinstalls stock 0.5.2 over the top, so this
# needs re-running after the launcher touches the Mods folder.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODS="$HOME/Library/Application Support/Balatro/Mods/multiplayer-0.5.2"

[ -d "$MODS" ] || { echo "not found: $MODS" >&2; exit 1; }

rsync -a --delete --exclude='.git/' --exclude='.claude/' "$REPO/" "$MODS/"

fail=0
grep -q 'sendTail' "$MODS/networking/socket.lua"                || { echo "MISSING: queue fix";      fail=1; }
grep -q 'reassert_ready_blind' "$MODS/networking/action_handlers.lua" || { echo "MISSING: ready re-assert"; fail=1; }
grep -q 'link_down' "$MODS/ui/game/timer.lua"                   || { echo "MISSING: timer gate";     fail=1; }
n=$(find "$HOME/Library/Application Support/Balatro/Mods" -maxdepth 2 -name Multiplayer.json | wc -l | tr -d ' ')
[ "$n" = "1" ] || { echo "WARNING: $n Multiplayer.json found — duplicate mod folders"; fail=1; }

[ "$fail" = "0" ] && echo "patched build installed and verified" || { echo "verification FAILED" >&2; exit 1; }
