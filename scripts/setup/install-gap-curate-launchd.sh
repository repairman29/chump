#!/usr/bin/env bash
# install-gap-curate-launchd.sh — INFRA-637
# Installs a launchd job that runs gap-curate.sh daily at 04:00 local time.
# Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep com.chump.gap-curate
# To run immediately:
#   launchctl start com.chump.gap-curate
# To disable:
#   launchctl unload ~/Library/LaunchAgents/com.chump.gap-curate.plist
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="com.chump.gap-curate.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$REPO/logs"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.gap-curate</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/gap-curate.sh</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$REPO</string>

  <!-- Run at 04:00 local time every day. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>4</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <key>RunAtLoad</key>
  <false/>

  <key>ThrottleInterval</key>
  <integer>300</integer>

  <key>StandardOutPath</key>
  <string>$REPO/logs/gap-curate.out.log</string>

  <key>StandardErrorPath</key>
  <string>$REPO/logs/gap-curate.err.log</string>
</dict>
</plist>
EOF

# Unload existing instance if loaded (ignore errors — may not be loaded).
launchctl unload "$DEST" 2>/dev/null || true

launchctl load "$DEST"

echo "[install-gap-curate] installed: $DEST"
echo "[install-gap-curate] schedule: daily at 04:00 local time"
echo "[install-gap-curate] run now:  launchctl start com.chump.gap-curate"
echo "[install-gap-curate] disable:  launchctl unload $DEST"
