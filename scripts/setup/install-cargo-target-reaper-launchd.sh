#!/usr/bin/env bash
# install-cargo-target-reaper-launchd.sh — INFRA-1250
# Installs a weekly launchd job that runs cargo-target-reaper.sh --execute.
# Runs Sunday 04:00 local time (off-hours, weekly cadence).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABEL="dev.chump.cargo-target-reaper"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"
LOG_DIR="${HOME}/.chump/logs"

mkdir -p "$LOG_DIR"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REAPER}</string>
        <string>--execute</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>4</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cargo-target-reaper.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cargo-target-reaper-err.log</string>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "[install-cargo-target-reaper-launchd] Installed: ${LABEL}"
echo "[install-cargo-target-reaper-launchd] Runs: Sundays at 04:00 local time"
echo "[install-cargo-target-reaper-launchd] Logs: ${LOG_DIR}/cargo-target-reaper.log"
echo "[install-cargo-target-reaper-launchd] Manual run: bash ${REAPER} --execute"
