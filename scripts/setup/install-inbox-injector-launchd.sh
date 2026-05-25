#!/usr/bin/env bash
# scripts/setup/install-inbox-injector-launchd.sh — INFRA-2014

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/inbox-injector.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.inbox-injector.plist"

[[ -x "$SCRIPT" ]] || { echo "missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.inbox-injector</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>10</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.chump-locks/inbox-injector.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/inbox-injector.log</string>
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

echo "[install-inbox-injector] installed launchd at $PLIST (10sec cadence)"
echo "[install-inbox-injector] watches .chump-locks/inbox/*.jsonl for CRIT/EMERGENCY messages"
echo "[install-inbox-injector] tmux send-keys to recipient pane on detection"
echo "[install-inbox-injector] disable: CHUMP_INBOX_INJECTOR_PAUSE=1"
echo "[install-inbox-injector] inspect: launchctl print gui/\$(id -u)/com.chump.inbox-injector"
echo "[install-inbox-injector] logs:    tail -f ${REPO_ROOT}/.chump-locks/inbox-injector.log"
