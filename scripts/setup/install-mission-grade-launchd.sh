#!/usr/bin/env bash
# install-mission-grade-launchd.sh — INFRA-599: install launchd agent that
# runs `chump mission-grade` every 30 minutes, emitting a kind=mission_grade
# event to .chump-locks/ambient.jsonl so the operator never has to ask
# "are we on mission?" manually.
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.mission-grade.plist
# Force fire: launchctl start dev.chump.mission-grade
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.mission-grade.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.mission-grade</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$HOME/.cargo/bin/chump mission-grade</string>
  </array>
  <!-- Every 30 minutes. Emits kind=mission_grade to ambient.jsonl so the
       operator dashboard and fleet workers can check pillar health without
       running the subcommand manually. -->
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-mission-grade.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-mission-grade.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>CHUMP_REPO_ROOT</key>
    <string>$REPO</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.mission-grade" || true
echo
echo "Fires every 30 min (RunAtLoad=true so it runs now too)."
echo "Force fire  : launchctl start dev.chump.mission-grade"
echo "Tail logs   : tail -f /tmp/chump-mission-grade.{out,err}.log"
echo "Check event : tail -5 $REPO/.chump-locks/ambient.jsonl | grep mission_grade"
