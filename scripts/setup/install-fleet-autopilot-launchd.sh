#!/usr/bin/env bash
# scripts/setup/install-fleet-autopilot-launchd.sh — META-090
#
# Install com.chump.fleet-autopilot launchd agent that fires the autopilot
# master heartbeat every 5 minutes. The heartbeat is a thin liveness check
# that reports daemon-set health and emits autopilot_partial if anything
# slipped (e.g. another launchd agent was unloaded externally).
#
# This installer is invoked by `bash scripts/coord/fleet-autopilot.sh start`
# as the master heartbeat layer. Operator can also run it standalone.
#
# Usage:
#   bash scripts/setup/install-fleet-autopilot-launchd.sh             # install + load
#   bash scripts/setup/install-fleet-autopilot-launchd.sh --uninstall

set -euo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "skip: not macOS"; exit 0 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLIST_NAME="com.chump.fleet-autopilot"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
AUTOPILOT_SCRIPT="$REPO_ROOT/scripts/coord/fleet-autopilot.sh"
LOG_BASE="$REPO_ROOT/.chump-locks/autopilot-logs"

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$PLIST_PATH" ]]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "uninstalled $PLIST_NAME"
    else
        echo "$PLIST_NAME not installed"
    fi
    exit 0
fi

if [[ ! -x "$AUTOPILOT_SCRIPT" ]]; then
    echo "FAIL: $AUTOPILOT_SCRIPT not found or not executable"
    exit 1
fi

mkdir -p "$(dirname "$PLIST_PATH")"
mkdir -p "$LOG_BASE"

LAUNCHD_PATH="$HOME/.cargo/bin:$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${AUTOPILOT_SCRIPT}</string>
        <string>heartbeat</string>
    </array>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <key>StandardOutPath</key>
    <string>${LOG_BASE}/heartbeat-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_BASE}/heartbeat-stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${LAUNCHD_PATH}</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>CHUMP_REPO_ROOT</key>
        <string>${REPO_ROOT}</string>
    </dict>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

echo "wrote $PLIST_PATH"

# Reload (unload first in case of upgrade)
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "loaded $PLIST_NAME"
echo "heartbeat fires every 5 minutes (StartInterval=300) + at load"
echo "logs: $LOG_BASE/heartbeat-{stdout,stderr}.log"
