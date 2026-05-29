#!/usr/bin/env bash
# install-cargo-target-reaper-launchd.sh — INFRA-1250 + INFRA-2125 + INFRA-2181
# Installs two launchd jobs for cargo-target-reaper.sh:
#
#   1. dev.chump.cargo-target-reaper         — hourly fallback (INFRA-2125 baseline,
#      RunAtLoad=true, StartInterval=3600, ThrottleInterval=60, ExitTimeOut=600)
#
#   2. dev.chump.cargo-target-reaper-event   — event-listener daemon (INFRA-2181,
#      KeepAlive=true, polls ambient.jsonl every 30s for kind=integration_cycle_shipped,
#      fires reap within 60s of each ship event). Installed only when
#      CHUMP_CARGO_REAPER_EVENT_MODE=1 (or --event-mode flag); skipped otherwise
#      so Wave 1 can enable it once the integration daemon is active.
#
# Usage:
#   bash install-cargo-target-reaper-launchd.sh            # hourly only (Phase 1 dry-run default)
#   bash install-cargo-target-reaper-launchd.sh --event-mode  # hourly + event listener

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LABEL_HOURLY="dev.chump.cargo-target-reaper"
LABEL_EVENT="dev.chump.cargo-target-reaper-event"
PLIST_HOURLY="${HOME}/Library/LaunchAgents/${LABEL_HOURLY}.plist"
PLIST_EVENT="${HOME}/Library/LaunchAgents/${LABEL_EVENT}.plist"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"
LOG_DIR="${HOME}/.chump/logs"

# --event-mode flag or CHUMP_CARGO_REAPER_EVENT_MODE=1 enables the event daemon
EVENT_MODE="${CHUMP_CARGO_REAPER_EVENT_MODE:-0}"
for _arg in "$@"; do
    [[ "$_arg" == "--event-mode" ]] && EVENT_MODE=1
done

mkdir -p "$LOG_DIR"

# ── 1. Hourly fallback plist (INFRA-2125 fixes preserved) ───────────────────
cat > "$PLIST_HOURLY" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL_HOURLY}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REAPER}</string>
        <string>--execute</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>ThrottleInterval</key>
    <integer>60</integer>
    <key>ExitTimeOut</key>
    <integer>600</integer>
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

launchctl unload "$PLIST_HOURLY" 2>/dev/null || true
launchctl load "$PLIST_HOURLY"
echo "[install-cargo-target-reaper-launchd] Installed hourly fallback: ${LABEL_HOURLY}"
echo "[install-cargo-target-reaper-launchd]   Runs: hourly (StartInterval=3600) + at load"
echo "[install-cargo-target-reaper-launchd]   Logs: ${LOG_DIR}/cargo-target-reaper.log"

# ── 2. Event-listener daemon (INFRA-2181, opt-in) ───────────────────────────
if [[ "$EVENT_MODE" == "1" ]]; then
    cat > "$PLIST_EVENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL_EVENT}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REAPER}</string>
        <string>--event-listen</string>
        <string>--execute</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cargo-target-reaper-event.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cargo-target-reaper-event-err.log</string>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

    launchctl unload "$PLIST_EVENT" 2>/dev/null || true
    launchctl load "$PLIST_EVENT"
    echo "[install-cargo-target-reaper-launchd] Installed event-listener daemon: ${LABEL_EVENT}"
    echo "[install-cargo-target-reaper-launchd]   Triggers on: kind=integration_cycle_shipped (30s poll)"
    echo "[install-cargo-target-reaper-launchd]   Logs: ${LOG_DIR}/cargo-target-reaper-event.log"
else
    echo "[install-cargo-target-reaper-launchd] Event-listener daemon NOT installed (pass --event-mode or set CHUMP_CARGO_REAPER_EVENT_MODE=1 to enable)"
fi

echo "[install-cargo-target-reaper-launchd] Manual run: bash ${REAPER} --execute"
echo "[install-cargo-target-reaper-launchd] Event-listen test: bash ${REAPER} --event-listen --execute"
