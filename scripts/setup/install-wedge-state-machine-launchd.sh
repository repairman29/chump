#!/usr/bin/env bash
# scripts/setup/install-wedge-state-machine-launchd.sh — INFRA-1994 (Phase 3)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/wedge-state-machine.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.wedge-state-machine.plist"

[[ -x "$SCRIPT" ]] || { echo "missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.wedge-state-machine</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.chump-locks/wedge-state-machine.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/wedge-state-machine.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo "[install-wedge-state-machine] installed launchd at $PLIST (5min cadence)"
echo "[install-wedge-state-machine] consumes wedge_detected from ambient.jsonl, emits remediations"
echo "[install-wedge-state-machine] inspect: launchctl print gui/\$(id -u)/com.chump.wedge-state-machine"
echo "[install-wedge-state-machine] logs:    tail -f ${REPO_ROOT}/.chump-locks/wedge-state-machine.log"
