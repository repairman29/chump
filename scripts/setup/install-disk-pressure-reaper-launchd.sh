#!/usr/bin/env bash
# scripts/setup/install-disk-pressure-reaper-launchd.sh — INFRA-1471

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SRC="$REPO_ROOT/scripts/plists/dev.chump.disk-pressure-reaper.plist"
DST="$HOME/Library/LaunchAgents/dev.chump.disk-pressure-reaper.plist"

[ -f "$SRC" ] || { echo "missing source plist: $SRC" >&2; exit 1; }
[ -x "$REPO_ROOT/scripts/coord/disk-pressure-reaper.sh" ] || \
  { echo "disk-pressure-reaper.sh not executable" >&2; exit 1; }

mkdir -p "$(dirname "$DST")"
launchctl unload "$DST" 2>/dev/null || true
cp "$SRC" "$DST"
launchctl load "$DST" || { echo "launchctl load failed" >&2; exit 1; }
echo "installed: $DST"
echo "running every 15 min. Logs: /tmp/chump-disk-pressure-reaper.log"
echo "uninstall: launchctl unload $DST && rm $DST"
