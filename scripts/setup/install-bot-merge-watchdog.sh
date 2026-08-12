#!/usr/bin/env bash
# install-bot-merge-watchdog.sh — INFRA-1006
#
# Installs the bot-merge watchdog as a launchd agent (macOS) or cron job (Linux).
# Idempotent: safe to re-run.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge-watchdog.sh"
PLIST_SRC="$REPO_ROOT/launchd/com.chump.bot-merge-watchdog.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.chump.bot-merge-watchdog.plist"

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
    echo "[install-bot-merge-watchdog] launchd agent loaded: com.chump.bot-merge-watchdog"
else
    # Linux: cron every 5 min.
    CRON_LINE="*/5 * * * * $SCRIPT >> $REPO_ROOT/.chump-locks/bot-merge-watchdog.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'bot-merge-watchdog'; echo "$CRON_LINE" ) | crontab -
    echo "[install-bot-merge-watchdog] cron job installed (every 5 min)"
fi
