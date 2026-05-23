#!/usr/bin/env bash
# install-curator-jit-scheduler-launchd.sh — INFRA-1892
#
# Idempotent installer for the curator-jit-scheduler launchd agent. The
# daemon tails .chump-locks/ambient.jsonl and auto-broadcasts next-gap
# assignments to curator-opus-* sessions on DONE events, replacing the
# orchestrator-as-pebble-scheduler antipattern.
#
# Usage : scripts/setup/install-curator-jit-scheduler-launchd.sh
# Verify: launchctl print "gui/$(id -u)/com.chump.curator-jit-scheduler"
# Logs  : /tmp/chump-curator-jit-scheduler.{out,err}.log
# Unload: launchctl bootout "gui/$(id -u)/com.chump.curator-jit-scheduler"
# Bypass: set CHUMP_JIT_SCHEDULER_DISABLED=1 in the operator env to no-op
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON_SCRIPT="$REPO_ROOT/scripts/coord/curator-jit-scheduler.sh"
PLIST_LABEL="com.chump.curator-jit-scheduler"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

if [[ ! -x "$DAEMON_SCRIPT" ]]; then
    echo "ERROR: daemon script not found or not executable: $DAEMON_SCRIPT" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-lc</string>
        <string>${DAEMON_SCRIPT}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <!-- Long-running tail-follow daemon. -->
    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/chump-curator-jit-scheduler.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chump-curator-jit-scheduler.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin</string>
    </dict>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || \
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH"

echo "[install-curator-jit-scheduler] installed: $PLIST_PATH"
echo "[install-curator-jit-scheduler] verify : launchctl print \"gui/\$(id -u)/${PLIST_LABEL}\""
echo "[install-curator-jit-scheduler] logs   : /tmp/chump-curator-jit-scheduler.{out,err}.log"
echo "[install-curator-jit-scheduler] unload : launchctl bootout \"gui/\$(id -u)/${PLIST_LABEL}\""
echo "[install-curator-jit-scheduler] bypass : export CHUMP_JIT_SCHEDULER_DISABLED=1"
