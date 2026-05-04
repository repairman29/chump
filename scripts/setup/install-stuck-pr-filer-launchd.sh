#!/usr/bin/env bash
# install-stuck-pr-filer-launchd.sh — INFRA-307 hourly LaunchAgent installer
# for scripts/ops/stuck-pr-filer.sh. Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep dev.chump.stuck-pr-filer
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.stuck-pr-filer.plist
set -euo pipefail

# INFRA-451: resolve to the *main* worktree (not the linked worktree this
# install script may be running from), so the plist absolute path survives
# worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.stuck-pr-filer.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.stuck-pr-filer</string>
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
launchctl list | grep -F "dev.chump.stuck-pr-filer" || true
