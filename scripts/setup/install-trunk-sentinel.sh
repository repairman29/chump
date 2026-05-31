#!/usr/bin/env bash
# scripts/setup/install-trunk-sentinel.sh — Trunk Health Sentinel launchd installer
#
# Idempotently installs the launchd agent that runs trunk-sentinel-daemon.sh
# every 60 seconds (StartInterval: 60).
#
# Usage:
#   bash scripts/setup/install-trunk-sentinel.sh        # install + load
#   launchctl unload ~/Library/LaunchAgents/com.chump.trunk-sentinel.plist
#
# Does NOT start the daemon if already loaded — unloads first to pick up
# any plist changes, then loads fresh (idempotent pattern from INFRA-1779).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"

LABEL="com.chump.trunk-sentinel"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BOT_SCRIPT="$ROOT/scripts/coord/trunk-sentinel-daemon.sh"
LOG_OUT="$HOME/.chump/logs/trunk-sentinel.out"
LOG_ERR="$HOME/.chump/logs/trunk-sentinel.err"
INTERVAL_S=60

if [[ ! -f "$BOT_SCRIPT" ]]; then
    echo "ERROR: $BOT_SCRIPT not found — daemon must land first." >&2
    exit 2
fi
[[ -x "$BOT_SCRIPT" ]] || chmod +x "$BOT_SCRIPT"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.chump/logs"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${BOT_SCRIPT}</string>
        <string>tick</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <!-- META-248: explicit absolute path to ambient.jsonl so the daemon
             does not compute it relative to a stale /tmp worktree under
             launchd's execution context. -->
        <key>CHUMP_AMBIENT_PATH</key>
        <string>${ROOT}/.chump-locks/ambient.jsonl</string>
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST}"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "Loaded launchd job ${LABEL}"
echo "  Cadence: every ${INTERVAL_S}s (RunAtLoad=true)"
echo "  Stdout:  ${LOG_OUT}"
echo "  Stderr:  ${LOG_ERR}"
echo "  Verify:  launchctl list | grep ${LABEL}"
echo "  Disable: launchctl unload ${PLIST}"
