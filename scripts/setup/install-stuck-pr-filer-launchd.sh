#!/usr/bin/env bash
# install-stuck-pr-filer-launchd.sh — INFRA-307 hourly LaunchAgent installer
# for scripts/ops/stuck-pr-filer.sh. Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep ai.openclaw.chump-stuck-pr-filer
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-stuck-pr-filer.plist
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST_NAME="ai.openclaw.chump-stuck-pr-filer.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-stuck-pr-filer</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/stuck-pr-filer.sh</string>
  </array>
  <!-- Hourly. File-once-per-PR dedup is built into the script (it reads
       open INFRA gaps and skips PRs whose stuck-pr filing already exists),
       so re-running is idempotent. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-stuck-pr-filer.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-stuck-pr-filer.err.log</string>
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
launchctl list | grep -F "ai.openclaw.chump-stuck-pr-filer" || true
