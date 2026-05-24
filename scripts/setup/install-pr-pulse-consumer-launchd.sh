#!/usr/bin/env bash
# scripts/setup/install-pr-pulse-consumer-launchd.sh — INFRA-1898
#
# Installs the pr-pulse-consumer launchd job (one-shot, cron-style 5min cadence).
# Pairs with INFRA-1897 pr-pulse (which emits every 5min) so the consumer fires
# right after each pulse snapshot lands.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/pr-pulse-consumer.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.pr-pulse-consumer.plist"

[[ -x "$SCRIPT" ]] || { echo "missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.pr-pulse-consumer</string>
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
    <string>${REPO_ROOT}/.chump-locks/pr-pulse-consumer.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/pr-pulse-consumer.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

# Unload if previously loaded (idempotent reinstall)
launchctl unload "$PLIST" 2>/dev/null || true

launchctl load "$PLIST"

echo "[install-pr-pulse-consumer-launchd] installed at $PLIST"
echo "[install-pr-pulse-consumer-launchd] cadence: every 300s (matches pr-pulse INFRA-1897)"
echo "[install-pr-pulse-consumer-launchd] logs: $REPO_ROOT/.chump-locks/pr-pulse-consumer.log"
echo ""
echo "Manual test (immediate run, no launchd needed):"
echo "  bash $SCRIPT"
echo ""
echo "Uninstall:"
echo "  launchctl unload $PLIST && rm $PLIST"
