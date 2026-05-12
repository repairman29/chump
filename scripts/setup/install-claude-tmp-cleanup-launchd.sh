#!/usr/bin/env bash
# install-claude-tmp-cleanup-launchd.sh — INFRA-400
# Installs a launchd agent that runs cleanup-claude-tmp.sh daily at 04:00.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../dev/cleanup-claude-tmp.sh"
PLIST_LABEL="com.chump.claude-tmp-cleanup"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

if [[ ! -x "$CLEANUP_SCRIPT" ]]; then
    echo "ERROR: cleanup script not found or not executable: $CLEANUP_SCRIPT"
    exit 1
fi

CLEANUP_SCRIPT_ABS="$(cd "$(dirname "$CLEANUP_SCRIPT")" && pwd)/$(basename "$CLEANUP_SCRIPT")"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${CLEANUP_SCRIPT_ABS}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>4</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/chump-tmp-cleanup.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chump-tmp-cleanup.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

# Load or reload
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "[install-claude-tmp-cleanup] installed: $PLIST_PATH (runs daily at 04:00)"
echo "[install-claude-tmp-cleanup] test: launchctl start $PLIST_LABEL"
