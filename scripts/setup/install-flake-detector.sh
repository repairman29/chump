#!/usr/bin/env bash
# install-flake-detector.sh — META-141 idempotent LaunchAgent installer.
#
# Installs com.chump.flake-detector.plist as a macOS LaunchAgent that
# runs scripts/coord/flake-detector.sh every 30 minutes.
#
# After install:
#   launchctl list | grep chump.flake-detector
#
# Manual run:
#   launchctl start com.chump.flake-detector
#   tail /tmp/chump-flake-detector.out.log
#
# Uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.chump.flake-detector.plist
#   rm ~/Library/LaunchAgents/com.chump.flake-detector.plist
#
# Tunables:
#   CHUMP_FLAKEDETECTOR_INTERVAL=1800   run interval in seconds (default: 30 min)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.flake-detector.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
INTERVAL="${CHUMP_FLAKEDETECTOR_INTERVAL:-1800}"
PATH_VALUE="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.flake-detector</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO}/scripts/coord/flake-detector.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-flake-detector.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-flake-detector.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Unload existing instance if present (idempotent)
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-flake-detector] installed $DEST (every ${INTERVAL}s)"
echo "[install-flake-detector] verify: launchctl list | grep chump.flake-detector"
echo "[install-flake-detector] logs:   tail /tmp/chump-flake-detector.out.log"
echo "[install-flake-detector] NOTE: operator must run this manually post-merge — not run by CI"
