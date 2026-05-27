#!/usr/bin/env bash
# scripts/setup/install-wizard-daemon-launchd.sh — META-109 Phase 1
#
# Installs the wizard-daemon launchd job (5-minute cadence).
# The daemon is DEFAULT DISABLED: it only acts when CHUMP_WIZARD_DAEMON_ENABLED=1
# is set in the plist environment. Operator must opt in after validating Sprint 1-3
# floor primitives are stable.
#
# Idempotent: unload + reload if already installed.
#
# Usage:
#   bash scripts/setup/install-wizard-daemon-launchd.sh
#   bash scripts/setup/install-wizard-daemon-launchd.sh --enable   # set ENABLED=1 in plist
#   bash scripts/setup/install-wizard-daemon-launchd.sh --uninstall
#
# Kill switch (no plist unload needed):
#   launchctl setenv CHUMP_WIZARD_DAEMON_PAUSE 1
#   OR: launchctl unload ~/Library/LaunchAgents/com.chump.wizard-daemon.plist

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/wizard-daemon.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.wizard-daemon.plist"

ENABLE_NOW=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable)     ENABLE_NOW=1; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --help|-h)    sed -n '2,22p' "$0"; exit 0 ;;
        *) shift ;;
    esac
done

if [[ "$UNINSTALL" == "1" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "[install-wizard-daemon] uninstalled plist at $PLIST"
    exit 0
fi

[[ -x "$SCRIPT" ]] || { echo "ERROR: missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

WIZARD_ENABLED="0"
[[ "$ENABLE_NOW" == "1" ]] && WIZARD_ENABLED="1"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.wizard-daemon</string>
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
    <false/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.chump-locks/wizard-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/wizard-daemon.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
        <key>CHUMP_REPO_ROOT</key>
        <string>${REPO_ROOT}</string>
        <key>CHUMP_WIZARD_DAEMON_ENABLED</key>
        <string>${WIZARD_ENABLED}</string>
    </dict>
</dict>
</plist>
PLIST_EOF

# Unload if previously loaded (idempotent reinstall)
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo "[install-wizard-daemon] installed launchd at $PLIST (5-min cadence)"
if [[ "$ENABLE_NOW" == "1" ]]; then
    echo "[install-wizard-daemon] WARNING: daemon ENABLED (CHUMP_WIZARD_DAEMON_ENABLED=1)"
    echo "[install-wizard-daemon]   Only enable after Sprint 1-3 floor validation complete."
else
    echo "[install-wizard-daemon] daemon is DISABLED (default-OFF safety mode)"
    echo "[install-wizard-daemon]   To enable: bash $0 --enable"
    echo "[install-wizard-daemon]   OR: set CHUMP_WIZARD_DAEMON_ENABLED=1 in plist env"
fi
echo "[install-wizard-daemon] inspect: launchctl print gui/$(id -u)/com.chump.wizard-daemon"
echo "[install-wizard-daemon] logs:    tail -f ${REPO_ROOT}/.chump-locks/wizard-daemon.log"
echo "[install-wizard-daemon] kill:    CHUMP_WIZARD_DAEMON_PAUSE=1 OR launchctl unload $PLIST"
