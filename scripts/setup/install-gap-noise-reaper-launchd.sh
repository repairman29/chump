#!/usr/bin/env bash
# install-gap-noise-reaper-launchd.sh — RESILIENT-111. Idempotent LaunchAgent
# running scripts/ops/gap-noise-reaper.sh hourly (no Claude session needed).
# Verify: launchctl list | grep dev.chump.gap-noise-reaper
# Logs:   /tmp/chump-gap-noise-reaper.{out,err}.log
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/host-paths.sh
source "$SCRIPT_DIR/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
DEST="$HOME/Library/LaunchAgents/dev.chump.gap-noise-reaper.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat >"$DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.gap-noise-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/gap-noise-reaper.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-gap-noise-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-gap-noise-reaper.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"
echo "Installed and loaded: $DEST"
