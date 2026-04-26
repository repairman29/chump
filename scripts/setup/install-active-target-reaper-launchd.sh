#!/usr/bin/env bash
# install-active-target-reaper-launchd.sh — install daily LaunchAgent that
# purges stale `target/` directories in linked worktrees. Idempotent.
#
# Mirrors install-stale-worktree-reaper-launchd.sh. Runs once per day
# (StartInterval 86400) — target/ purges aren't urgent, just hygiene.
#
# Verify:
#   launchctl list | grep ai.openclaw.chump-active-target-reaper
# Logs:
#   /tmp/chump-active-target-reaper.out.log
#   /tmp/chump-active-target-reaper.err.log
# Disable:
#   launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-active-target-reaper.plist
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_NAME="ai.openclaw.chump-active-target-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-active-target-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/active-target-reaper.sh --execute</string>
  </array>
  <!-- Once per day. Purges target/ in worktrees with mtime > 7d, skipping
       active leases and worktrees with .chump-no-reap. -->
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-active-target-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-active-target-reaper.err.log</string>
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
launchctl list | grep -F "ai.openclaw.chump-active-target-reaper" || true
