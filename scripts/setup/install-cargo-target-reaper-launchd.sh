#!/usr/bin/env bash
# install-cargo-target-reaper-launchd.sh — INFRA-1250 + INFRA-2125
# Installs an hourly launchd job that runs cargo-target-reaper.sh --execute.
# Runs at load + every 3600 seconds (hourly). INFRA-2125: fixed RunAtLoad=true
# and replaced weekly StartCalendarInterval with hourly StartInterval.
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
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cargo-target-reaper.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cargo-target-reaper-err.log</string>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "[install-cargo-target-reaper-launchd] Installed: ${LABEL}"
echo "[install-cargo-target-reaper-launchd] Runs: hourly (StartInterval=3600) + at load"
echo "[install-cargo-target-reaper-launchd] Logs: ${LOG_DIR}/cargo-target-reaper.log"
echo "[install-cargo-target-reaper-launchd] Manual run: bash ${REAPER} --execute"
