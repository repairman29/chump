#!/usr/bin/env bash
# install-stale-pr-reaper-launchd.sh — INFRA-328: install hourly launchd
# agent that runs scripts/ops/stale-pr-reaper.sh.
#
# The stale-pr-reaper closes open PRs whose gaps already landed on main
# with the branch >15 commits behind, keeping the PR list aligned with
# the gap registry. The plist was previously hand-installed on each
# dogfood machine (verified Apr 16 + May 1 .bak on jeffadkins's box),
# so new machines silently lacked the reaper until someone noticed PR
# rot. This installer puts the install path in-tree so it matches every
# other launchd agent (gap-doctor-cron, ambient-rotate, reaper-watchdog,
# stale-worktree-reaper, overnight-research) under scripts/setup/.
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-stale-pr-reaper.plist
# Manual fire: launchctl start ai.openclaw.chump-stale-pr-reaper
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST_NAME="ai.openclaw.chump-stale-pr-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-stale-pr-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/stale-pr-reaper.sh</string>
  </array>
  <!-- Run once per hour. Scans open PRs and closes ones whose gaps are
       already done on main with the branch >15 commits behind. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-stale-pr-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-stale-pr-reaper.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- gh CLI needs HOME to find the auth token. -->
    <key>HOME</key>
    <string>$HOME</string>
  </dict>
</dict>
</plist>
EOF

# Reload (unload + load) so the new plist takes effect immediately.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-stale-pr-reaper] Installed: $DEST"
echo "[install-stale-pr-reaper] Schedule:  every 1 hour"
echo "[install-stale-pr-reaper] Logs:      /tmp/chump-stale-pr-reaper.{out,err}.log"
echo "[install-stale-pr-reaper] Verify:    launchctl list | grep ai.openclaw.chump-stale-pr-reaper"
echo "[install-stale-pr-reaper] Manual:    launchctl start ai.openclaw.chump-stale-pr-reaper"
echo "[install-stale-pr-reaper] Disable:   launchctl unload $DEST"
