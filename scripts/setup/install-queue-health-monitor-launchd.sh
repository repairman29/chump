#!/usr/bin/env bash
# install-queue-health-monitor-launchd.sh — INFRA-052 LaunchAgent installer.
#
# Installs the hourly queue health monitor (scripts/ops/queue-health-monitor.sh).
# Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep ai.openclaw.chump-queue-health-monitor
#
# To run immediately (verify it works):
#   launchctl start ai.openclaw.chump-queue-health-monitor
#   tail -f /tmp/chump-queue-health-monitor.out.log
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-queue-health-monitor.plist

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST_NAME="ai.openclaw.chump-queue-health-monitor.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-queue-health-monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/queue-health-monitor.sh --quiet</string>
  </array>
  <!-- Hourly. Detects: stuck PRs (>45m BLOCKED/DIRTY), silent agents
       (>90m no commits), fat worktrees (>5GB target/). Writes to
       .chump/health.jsonl and .chump/alerts.log; emits ALERT events to
       .chump-locks/ambient.jsonl so sibling agents see findings in their
       FLEET-019 SessionStart digest. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-queue-health-monitor.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-queue-health-monitor.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Reload (unload first; ignore failure if not loaded).
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "ai.openclaw.chump-queue-health-monitor" || true
echo
echo "First run is in 1 hour. To run immediately:"
echo "  launchctl start ai.openclaw.chump-queue-health-monitor"
echo "  tail -f /tmp/chump-queue-health-monitor.out.log"
