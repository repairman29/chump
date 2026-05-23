#!/usr/bin/env bash
# install-flake-catalog-launchd.sh — INFRA-1866
# Installs the daily flake-catalog audit LaunchAgent. Idempotent.
#
# After install:
#   launchctl list | grep chump.audit-flake-catalog
#
# Manual run:
#   launchctl start com.chump.audit-flake-catalog
#   tail /tmp/chump-audit-flake-catalog.out.log
#
# Override schedule for testing:
#   CHUMP_FLAKEAUDIT_HOUR=10 CHUMP_FLAKEAUDIT_MINUTE=30 ./install-flake-catalog-launchd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.audit-flake-catalog.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
HOUR="${CHUMP_FLAKEAUDIT_HOUR:-9}"
MINUTE="${CHUMP_FLAKEAUDIT_MINUTE:-30}"
PATH_VALUE="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.audit-flake-catalog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/ops/audit-flake-catalog.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${HOUR}</integer>
    <key>Minute</key>
    <integer>${MINUTE}</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-audit-flake-catalog.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-audit-flake-catalog.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-flake-catalog-launchd] installed $DEST (daily ${HOUR}:${MINUTE} local)"
echo "[install-flake-catalog-launchd] verify: launchctl list | grep chump.audit-flake-catalog"
