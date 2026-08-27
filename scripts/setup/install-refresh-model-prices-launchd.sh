#!/usr/bin/env bash
# install-refresh-model-prices-launchd.sh — INFRA-1564 LaunchAgent installer.
#
# Installs the weekly refresh-model-prices check (scripts/dev/refresh-model-prices.sh).
# Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep com.chump.refresh-model-prices
#
# To run immediately (verify it works):
#   launchctl start com.chump.refresh-model-prices
#   tail -f /tmp/chump-refresh-model-prices.out.log
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/com.chump.refresh-model-prices.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="com.chump.refresh-model-prices.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ "${1:-}" == "--check" ]]; then
  launchctl list 2>/dev/null | grep -q com.chump.refresh-model-prices
  exit $?
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.refresh-model-prices</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/dev/refresh-model-prices.sh --refresh --check-registry</string>
  </array>
  <key>StartInterval</key>
  <integer>604800</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-refresh-model-prices.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-refresh-model-prices.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "com.chump.refresh-model-prices" || true
echo
echo "First run is in 7d. To run immediately:"
echo "  launchctl start com.chump.refresh-model-prices"
echo "  tail -f /tmp/chump-refresh-model-prices.out.log"
