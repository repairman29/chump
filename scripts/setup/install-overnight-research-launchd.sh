#!/usr/bin/env bash
# install-overnight-research-launchd.sh — install the nightly overnight-research
# LaunchAgent (macOS). Runs scripts/eval/run-overnight-research.sh once a day at
# 02:00 local time. Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep ai.openclaw.chump-overnight-research
#
# To run on demand (smoke test):
#   launchctl start ai.openclaw.chump-overnight-research
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-overnight-research.plist
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_NAME="ai.openclaw.chump-overnight-research.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Hour/minute can be overridden for testing (CHUMP_OVERNIGHT_HOUR=22 ./install...)
HOUR="${CHUMP_OVERNIGHT_HOUR:-2}"
MINUTE="${CHUMP_OVERNIGHT_MINUTE:-0}"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-overnight-research</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/eval/run-overnight-research.sh</string>
  </array>
  <!-- Once per day at ${HOUR}:$(printf '%02d' "$MINUTE") local time. Runs every job
       in scripts/overnight/ in order, with a 1h per-job timeout. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-overnight-research.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-overnight-research.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

# Reload (unload first; ignore failure if not loaded).
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
echo "Schedule: ${HOUR}:$(printf '%02d' "$MINUTE") local, daily"
launchctl list | grep -F "ai.openclaw.chump-overnight-research" || true
