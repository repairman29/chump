#!/usr/bin/env bash
# install-fleet-auto-restart-launchd.sh — INFRA-611
#
# Installs a macOS LaunchAgent that runs fleet-autorestart-daemon.sh as a
# periodic safety-net check every 10 minutes (StartInterval 600).
#
# The daemon itself is also spawned by run-fleet.sh for real-time event
# watching (INFRA-602 pattern). This launchd job provides an independent
# safety net that catches conditions even when the fleet was launched manually
# without run-fleet.sh.
#
# Verify:
#   launchctl list | grep dev.chump.fleet-auto-restart
# Logs:
#   /tmp/chump-fleet-auto-restart.out.log
#   /tmp/chump-fleet-auto-restart.err.log
# Disable (operator override — same effect as CHUMP_FLEET_AUTO_RESTART=0):
#   launchctl unload ~/Library/LaunchAgents/dev.chump.fleet-auto-restart.plist
# Re-enable:
#   launchctl load ~/Library/LaunchAgents/dev.chump.fleet-auto-restart.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="dev.chump.fleet-auto-restart.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

# The daemon exits immediately when no fleet tmux session is running, so
# running it every 10 min is safe — it is a no-op unless a fleet is live.
cat > "$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.fleet-auto-restart</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/dispatch/fleet-autorestart-daemon.sh</string>
  </array>
  <!-- Run every 10 minutes. No-ops when no fleet tmux session is live. -->
  <key>StartInterval</key>
  <integer>600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-fleet-auto-restart.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-fleet-auto-restart.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>REPO_ROOT</key>
    <string>$REPO</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.fleet-auto-restart" || true
