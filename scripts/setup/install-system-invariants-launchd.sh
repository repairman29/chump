#!/usr/bin/env bash
# install-system-invariants-launchd.sh — META-033
#
# Installs a 10-min LaunchAgent that asserts system invariants and emits
# kind=invariant_violation to ambient.jsonl on breach. Idempotent.
#
# Verify:  launchctl list | grep dev.chump.system-invariants
# Logs:    /tmp/chump-system-invariants.out.log
# Disable: launchctl unload ~/Library/LaunchAgents/dev.chump.system-invariants.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.system-invariants.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$DEST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.system-invariants</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/system-invariants-monitor.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-system-invariants.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-system-invariants.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CHUMP_LOCK_DIR</key>
    <string>$REPO/.chump-locks</string>
  </dict>
</dict>
</plist>
EOF

# INFRA-451: bake path via git rev-parse --git-common-dir (not CWD) so the
# plist path stays stable even if the operator cds to a linked worktree.
echo "[install-system-invariants] Written: $DEST"

if launchctl list | grep -q "dev.chump.system-invariants" 2>/dev/null; then
    launchctl unload "$DEST" 2>/dev/null || true
fi
launchctl load "$DEST"
echo "[install-system-invariants] Loaded dev.chump.system-invariants (10-min interval)"
