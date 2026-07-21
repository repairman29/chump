#!/usr/bin/env bash
# install-ruleset-empty-watchdog.sh — META-146
#
# Installs the ruleset-empty watchdog as a launchd agent (macOS) or cron job
# (Linux). Idempotent: safe to re-run.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/ruleset-empty-watchdog.sh"
PLIST_SRC="$REPO_ROOT/launchd/com.chump.ruleset-empty-watchdog.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.chump.ruleset-empty-watchdog.plist"

[[ -f "$SCRIPT" ]] || { echo "ERROR: $SCRIPT not found"; exit 1; }
chmod +x "$SCRIPT"

if [[ "$(uname)" == "Darwin" ]]; then
    if [[ ! -f "$PLIST_SRC" ]]; then
        echo "ERROR: $PLIST_SRC not found — run from repo root after this PR merges"; exit 1
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    # Patch plist to use absolute repo path.
    sed "s|REPO_ROOT|$REPO_ROOT|g" "$PLIST_SRC" > "$PLIST_DEST"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load -w "$PLIST_DEST"
    echo "[install-ruleset-empty-watchdog] launchd agent loaded: com.chump.ruleset-empty-watchdog"
else
    # Linux: cron every 1 min.
    CRON_LINE="* * * * * $SCRIPT >> $REPO_ROOT/.chump-locks/ruleset-empty-watchdog.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'ruleset-empty-watchdog'; echo "$CRON_LINE" ) | crontab -
    echo "[install-ruleset-empty-watchdog] cron job installed (every 1 min)"
fi
