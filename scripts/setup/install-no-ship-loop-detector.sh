#!/usr/bin/env bash
# scripts/setup/install-no-ship-loop-detector.sh — RESILIENT-1573
# Idempotent installer: launchd agent on macOS, systemd --user timer on Linux.
# Both run scripts/coord/no-ship-loop-detector.sh every INTERVAL_S (default 600).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/coord/no-ship-loop-detector.sh"
INTERVAL_S="${CHUMP_NSL_INTERVAL_S:-600}"
[[ -f "$SCRIPT" ]] || { echo "ERROR: $SCRIPT missing" >&2; exit 2; }
chmod +x "$SCRIPT"
mkdir -p "$ROOT/.chump" "$ROOT/.chump-locks"

if [[ "$(uname)" == "Darwin" ]]; then
    LABEL="com.chump.no-ship-loop-detector"
    DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.chump/logs"
    cat > "$DEST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key><array><string>/bin/bash</string><string>${SCRIPT}</string><string>tick</string></array>
    <key>WorkingDirectory</key><string>${ROOT}</string>
    <key>StartInterval</key><integer>${INTERVAL_S}</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>${HOME}/.chump/logs/no-ship-loop-detector.out</string>
    <key>StandardErrorPath</key><string>${HOME}/.chump/logs/no-ship-loop-detector.err</string>
</dict>
</plist>
PL
    launchctl unload "$DEST" 2>/dev/null || true
    launchctl load "$DEST"
    echo "installed $LABEL"
else
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/chump-no-ship-loop-detector.service" <<UN
[Unit]
Description=chump no-ship-loop + crash-loop detector (RESILIENT-1573)

[Service]
Type=oneshot
WorkingDirectory=${ROOT}
ExecStart=/usr/bin/env bash ${SCRIPT} tick
Nice=10
UN
    cat > "$UNIT_DIR/chump-no-ship-loop-detector.timer" <<UN
[Unit]
Description=chump no-ship-loop detector timer (RESILIENT-1573)

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL_S}s
Persistent=true

[Install]
WantedBy=timers.target
UN
    systemctl --user daemon-reload
    systemctl --user enable --now chump-no-ship-loop-detector.timer
    echo "installed chump-no-ship-loop-detector.timer"
fi
