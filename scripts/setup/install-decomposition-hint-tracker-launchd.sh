#!/usr/bin/env bash
# install-decomposition-hint-tracker-launchd.sh — INFRA-1564 LaunchAgent installer.
#
# Installs the daily decomposition-hint-tracker (scripts/dev/decomposition-hint-tracker.sh).
# Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep com.chump.decomposition-hint-tracker
#
# To run immediately (verify it works):
#   launchctl start com.chump.decomposition-hint-tracker
#   tail -f /tmp/chump-decomposition-hint-tracker.out.log
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/com.chump.decomposition-hint-tracker.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="com.chump.decomposition-hint-tracker.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ "${1:-}" == "--check" ]]; then
  launchctl list 2>/dev/null | grep -q com.chump.decomposition-hint-tracker
  exit $?
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.decomposition-hint-tracker</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/dev/decomposition-hint-tracker.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-decomposition-hint-tracker.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-decomposition-hint-tracker.err.log</string>
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
launchctl list | grep -F "com.chump.decomposition-hint-tracker" || true
echo
echo "First run is in 24h. To run immediately:"
echo "  launchctl start com.chump.decomposition-hint-tracker"
echo "  tail -f /tmp/chump-decomposition-hint-tracker.out.log"
