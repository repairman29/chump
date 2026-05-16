#!/usr/bin/env bash
# scripts/setup/install-target-reaper-launchd.sh — INFRA-1349
#
# Installs dev.chump.target-reaper.plist into the user's launchd. Idempotent:
# unloads any existing copy first, then loads the current plist. Runs the
# script every 30 min; the script itself self-throttles based on disk pressure.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SRC="$REPO_ROOT/scripts/plists/dev.chump.target-reaper.plist"
DST="$HOME/Library/LaunchAgents/dev.chump.target-reaper.plist"

[ -f "$SRC" ] || { echo "missing source plist: $SRC" >&2; exit 1; }
[ -x "$REPO_ROOT/scripts/coord/target-dir-reaper.sh" ] || \
  { echo "target-dir-reaper.sh not executable" >&2; exit 1; }

mkdir -p "$(dirname "$DST")"
launchctl unload "$DST" 2>/dev/null || true
cp "$SRC" "$DST"
launchctl load "$DST" || { echo "launchctl load failed" >&2; exit 1; }
echo "installed: $DST"
echo "running every 30 min. Logs: /tmp/chump-target-reaper.log"
echo "uninstall: launchctl unload $DST && rm $DST"
