#!/usr/bin/env bash
# install-reaper-watchdog-launchd.sh — install the reaper heartbeat watchdog
# LaunchAgent (INFRA-120). Runs every 30 minutes; ALERTs into ambient.jsonl
# when any of the stale-* reapers (pr / worktree / branch) misses its expected
# cadence by more than the per-reaper threshold.
#
# Idempotent. After install:
#   launchctl list | grep ai.openclaw.chump-reaper-watchdog
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-reaper-watchdog.plist

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST_NAME="ai.openclaw.chump-reaper-watchdog.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-reaper-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/reaper-heartbeat-watchdog.sh --quiet</string>
  </array>
  <!-- Every 30 minutes. Cheap (a few stat() calls + maybe one ALERT line). -->
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-reaper-watchdog.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-reaper-watchdog.err.log</string>
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
launchctl list | grep -F "ai.openclaw.chump-reaper-watchdog" || true
