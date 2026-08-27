#!/usr/bin/env bash
# install-fleet-version-skew-detect-launchd.sh — INFRA-1564 LaunchAgent installer.
#
# Installs the 6-hourly fleet-version-skew-detect check
# (scripts/dev/fleet-version-skew-detect.sh). Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep com.chump.fleet-version-skew-detect
#
# To run immediately (verify it works):
#   launchctl start com.chump.fleet-version-skew-detect
#   tail -f /tmp/chump-fleet-version-skew-detect.out.log
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/com.chump.fleet-version-skew-detect.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="com.chump.fleet-version-skew-detect.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ "${1:-}" == "--check" ]]; then
  launchctl list 2>/dev/null | grep -q com.chump.fleet-version-skew-detect
  exit $?
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.fleet-version-skew-detect</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/dev/fleet-version-skew-detect.sh --quiet</string>
  </array>
  <key>StartInterval</key>
  <integer>21600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-fleet-version-skew-detect.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-fleet-version-skew-detect.err.log</string>
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
launchctl list | grep -F "com.chump.fleet-version-skew-detect" || true
echo
echo "First run is in 6h. To run immediately:"
echo "  launchctl start com.chump.fleet-version-skew-detect"
echo "  tail -f /tmp/chump-fleet-version-skew-detect.out.log"
