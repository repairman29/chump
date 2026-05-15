#!/usr/bin/env bash
# install-target-dir-reaper-launchd.sh — INFRA-1349
# Installs a launchd job that runs target-dir-reaper.sh --execute every 30 minutes.
# Prunes stale target/ directories in linked worktrees on disk pressure or idle timeout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABEL="dev.chump.target-dir-reaper"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
REAPER="${REPO_ROOT}/scripts/coord/target-dir-reaper.sh"

# Unload existing plist if installed
launchctl unload "$PLIST_PATH" 2>/dev/null || true

# Copy/overwrite from the repo's template plist
cp "${REPO_ROOT}/scripts/plists/${LABEL}.plist" "$PLIST_PATH"

# Substitute paths in the plist
sed -i "" "s|/Users/jeffadkins/Projects/Chump|${REPO_ROOT}|g" "$PLIST_PATH"

# Load the plist
launchctl load "$PLIST_PATH"

echo "[install-target-dir-reaper-launchd] Installed: ${LABEL}"
echo "[install-target-dir-reaper-launchd] Runs: every 30 minutes"
echo "[install-target-dir-reaper-launchd] Logs: /tmp/chump-target-dir-reaper.{out,err}.log"
echo "[install-target-dir-reaper-launchd] Manual run: bash ${REAPER} --execute"
echo "[install-target-dir-reaper-launchd] Verify: launchctl list | grep ${LABEL}"
echo "[install-target-dir-reaper-launchd] Disable: launchctl unload ${PLIST_PATH}"
