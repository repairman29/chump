#!/usr/bin/env bash
# install-stale-auditor-finding-reaper-launchd.sh — install hourly launchd
# agent that runs scripts/ops/stale-auditor-finding-reaper.sh --execute.
#
# Idempotent: safe to re-run.
# Disable: launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-auditor-reaper.plist
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_NAME="ai.openclaw.chump-auditor-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-auditor-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/stale-auditor-finding-reaper.sh --execute</string>
  </array>
  <!-- Once per hour. Closes auditor-filed gaps with no engagement after 30
       days (override with CHUMP_AUDITOR_REAPER_DAYS). If the underlying
       problem persists, the next overnight auditor run re-files it. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-auditor-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-auditor-reaper.err.log</string>
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

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "ai.openclaw.chump-auditor-reaper" || true
