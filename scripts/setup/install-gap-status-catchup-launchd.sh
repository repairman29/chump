#!/usr/bin/env bash
# install-gap-status-catchup-launchd.sh — INFRA-2230
# Installs the nightly gap-status catch-up LaunchAgent, the compensating
# control for auto-flip-on-merge silently no-oping in CI (see
# launchd/com.chump.gap-status-catchup.plist for root-cause detail).
# Idempotent.
#
# After install:
#   launchctl list | grep chump.gap-status-catchup
#
# Manual run:
#   launchctl start com.chump.gap-status-catchup
#   tail /tmp/chump-gap-status-catchup.out.log
#
# Override schedule for testing:
#   CHUMP_GAPCATCHUP_HOUR=4 CHUMP_GAPCATCHUP_MINUTE=30 ./install-gap-status-catchup-launchd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.gap-status-catchup.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
HOUR="${CHUMP_GAPCATCHUP_HOUR:-3}"
MINUTE="${CHUMP_GAPCATCHUP_MINUTE:-0}"
PATH_VALUE="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.gap-status-catchup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/ops/backfill-shipped-gaps.sh --days 2 --apply</string>
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
  <string>/tmp/chump-gap-status-catchup.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-gap-status-catchup.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>300</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  schedule: nightly at ${HOUR}:$(printf '%02d' "$MINUTE")"
echo "  verify: launchctl list | grep chump.gap-status-catchup"
echo "  on-demand: launchctl start com.chump.gap-status-catchup"
