#!/usr/bin/env bash
# install-stale-branch-reaper-launchd.sh — INFRA-388: daily LaunchAgent for
# scripts/ops/stale-branch-reaper.sh. Idempotent: safe to re-run.
#
# Without this installer, the heartbeat-watchdog ALERTs `kind=reaper_silent`
# every 30min cycle for the missing branch reaper (5+ ALERTs/day observed
# 2026-05-03). The reaper script itself shipped long ago; only the
# launchd plumbing was missing.
#
# After install:
#   launchctl list | grep dev.chump.stale-branch-reaper
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.stale-branch-reaper.plist
#
# Cadence: once per day (matches the reaper-watchdog's 48h alert threshold
# for branch reaper — 24h × 2x).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST_NAME="dev.chump.stale-branch-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.stale-branch-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/stale-branch-reaper.sh --execute</string>
  </array>
  <!-- Once per day. Stale-branch deletion is conservative (default
       STALE_DAYS_THRESHOLD=14 + must have no open PR), so daily is
       plenty. Watchdog alerts at 48h missed. -->
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-stale-branch-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-stale-branch-reaper.err.log</string>
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
launchctl list | grep -F "dev.chump.stale-branch-reaper" || true
