#!/usr/bin/env bash
# install-branch-protection-drift-launchd.sh — INFRA-121 LaunchAgent installer.
#
# Installs the daily branch-protection drift detector
# (scripts/ops/branch-protection-drift.sh). Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep ai.openclaw.chump-branch-protection-drift
#
# To run immediately (verify):
#   launchctl start ai.openclaw.chump-branch-protection-drift
#   tail -f /tmp/chump-branch-protection-drift.out.log
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-branch-protection-drift.plist

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST_NAME="ai.openclaw.chump-branch-protection-drift.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-branch-protection-drift</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/branch-protection-drift.sh --quiet</string>
  </array>
  <!-- Daily. Diffs live branch protection for main vs the checked-in
       baseline at docs/baselines/branch-protection-main.json. On drift,
       writes ALERT kind=queue_config_drift to ambient.jsonl + .chump/alerts.log
       so sibling agents see it in their FLEET-019 SessionStart digest.
       Closes the silent-disarm hole described in CLAUDE.md "If the merge
       queue is stuck" recovery section. -->
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-branch-protection-drift.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-branch-protection-drift.err.log</string>
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

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "ai.openclaw.chump-branch-protection-drift" || true
echo
echo "First run is in 24 hours. To run immediately:"
echo "  launchctl start ai.openclaw.chump-branch-protection-drift"
echo "  tail -f /tmp/chump-branch-protection-drift.out.log"
