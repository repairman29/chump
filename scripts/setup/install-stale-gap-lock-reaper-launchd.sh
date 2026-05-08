#!/usr/bin/env bash
# install-stale-gap-lock-reaper-launchd.sh — INFRA-676
# Installs a launchd job that runs stale-gap-lock-reaper.sh every 5 min.
# Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep dev.chump.stale-gap-lock-reaper
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.stale-gap-lock-reaper.plist
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.stale-gap-lock-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.stale-gap-lock-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/stale-gap-lock-reaper.sh --execute</string>
  </array>
  <!-- Every 5 minutes: sweep .gap-*.lock files whose session lease is gone. -->
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-stale-gap-lock-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-stale-gap-lock-reaper.err.log</string>
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
launchctl list | grep -F "dev.chump.stale-gap-lock-reaper" || true
