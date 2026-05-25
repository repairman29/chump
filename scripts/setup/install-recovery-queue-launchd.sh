#!/usr/bin/env bash
# scripts/setup/install-recovery-queue-launchd.sh — INFRA-1993 (THE FLOOR Phase 3)
#
# Installs the recovery-queue-service launchd job (60-second cadence).
# Pairs with scripts/coord/recovery-queue-service.sh which consumes
# operator_recovery_requested events.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/recovery-queue-service.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.recovery-queue-service.plist"

[[ -x "$SCRIPT" ]] || { echo "missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.recovery-queue-service</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.chump-locks/recovery-queue-service.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/recovery-queue-service.log</string>
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

echo "[install-recovery-queue] installed launchd at $PLIST (60s cadence)"
echo "[install-recovery-queue] DISABLED BY DEFAULT — operator must export CHUMP_RECOVERY_QUEUE_PAUSE=0 + restart fleet to enable"
echo "[install-recovery-queue] safety: set CHUMP_RECOVERY_QUEUE_PAUSE=1 to disable; CHUMP_RECOVERY_QUEUE_DRY_RUN=1 to plan-only"
echo "[install-recovery-queue] inspect: launchctl print gui/\$(id -u)/com.chump.recovery-queue-service"
echo "[install-recovery-queue] logs:    tail -f ${REPO_ROOT}/.chump-locks/recovery-queue-service.log"
