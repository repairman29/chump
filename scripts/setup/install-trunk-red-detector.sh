#!/usr/bin/env bash
# install-trunk-red-detector.sh — META-177 Lane C
#
# Installs the trunk-red-detector LaunchAgent so it runs every 5 min on
# macOS. Idempotent: safe to re-run if the daemon is already installed.
#
# Usage:
#   bash scripts/setup/install-trunk-red-detector.sh
#
# What it does:
#   1. Creates $HOME/.chump/logs/ for stdout/stderr capture.
#   2. Copies .chump/launchd/com.chump.trunk-red-detector.plist to
#      ~/Library/LaunchAgents/.
#   3. Bootstraps the agent via `launchctl bootstrap`.
#   4. Verifies the agent loaded with `launchctl list | grep trunk-red`.
#
# NOTE: this script only installs. To trigger an immediate run:
#   launchctl kickstart -k gui/$(id -u)/com.chump.trunk-red-detector
#
# To uninstall:
#   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chump.trunk-red-detector.plist
#   rm ~/Library/LaunchAgents/com.chump.trunk-red-detector.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLIST_SRC="$REPO_ROOT/.chump/launchd/com.chump.trunk-red-detector.plist"
PLIST_LABEL="com.chump.trunk-red-detector"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_DEST="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"
LOG_DIR="$HOME/.chump/logs"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'ERROR: install-trunk-red-detector.sh is macOS-only (launchd).\n' >&2
    printf 'On Linux, add a cron entry: */5 * * * * bash %s/scripts/coord/trunk-red-detector.sh\n' "$REPO_ROOT" >&2
    exit 1
fi

# ── 1. Create log directory ───────────────────────────────────────────────────
printf 'Creating log directory %s ...\n' "$LOG_DIR"
mkdir -p "$LOG_DIR"

# ── 2. Copy plist ─────────────────────────────────────────────────────────────
if [[ ! -f "$PLIST_SRC" ]]; then
    printf 'ERROR: plist not found at %s\n' "$PLIST_SRC" >&2
    exit 1
fi
printf 'Copying plist to %s ...\n' "$PLIST_DEST"
mkdir -p "$LAUNCH_AGENTS_DIR"
cp "$PLIST_SRC" "$PLIST_DEST"

# ── 3. Bootstrap (or reload if already loaded) ────────────────────────────────
UID_CURRENT="$(id -u)"
GUI_DOMAIN="gui/$UID_CURRENT"

# Unload first if already present (idempotent re-install).
if launchctl list "$PLIST_LABEL" >/dev/null 2>&1; then
    printf 'Agent already loaded; unloading for clean re-install ...\n'
    launchctl bootout "$GUI_DOMAIN" "$PLIST_DEST" 2>/dev/null || true
fi

printf 'Bootstrapping %s ...\n' "$PLIST_LABEL"
launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DEST"

# ── 4. Verify ─────────────────────────────────────────────────────────────────
printf 'Verifying ...\n'
if launchctl list | grep -q "$PLIST_LABEL"; then
    printf 'SUCCESS: %s is loaded and will run every 5 min.\n' "$PLIST_LABEL"
    printf '  Logs: %s/trunk-red-detector.out\n' "$LOG_DIR"
    printf '  Manual run: launchctl kickstart -k %s/%s\n' "$GUI_DOMAIN" "$PLIST_LABEL"
else
    printf 'ERROR: %s did not appear in launchctl list after bootstrap.\n' "$PLIST_LABEL" >&2
    printf 'Try: launchctl print %s/%s\n' "$GUI_DOMAIN" "$PLIST_LABEL" >&2
    exit 1
fi
