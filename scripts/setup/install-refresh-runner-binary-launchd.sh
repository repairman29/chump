#!/usr/bin/env bash
# scripts/setup/install-refresh-runner-binary-launchd.sh — CREDIBLE-076
#
# Install com.chump.refresh-runner-binary launchd agent that fires
# refresh-runner-binary.sh every 30 minutes. macOS only.
#
# Usage:
#   bash scripts/setup/install-refresh-runner-binary-launchd.sh           # install + load
#   bash scripts/setup/install-refresh-runner-binary-launchd.sh --uninstall

set -euo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "skip: not macOS"; exit 0 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLIST_NAME="com.chump.refresh-runner-binary"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
REFRESH_SCRIPT="$REPO_ROOT/scripts/setup/refresh-runner-binary.sh"
LOG_BASE="$REPO_ROOT/.chump-locks/binary-refresh-logs"

# Uninstall mode
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

if [[ ! -x "$REFRESH_SCRIPT" ]]; then
    echo "FAIL: $REFRESH_SCRIPT not found or not executable"
    exit 1
fi

mkdir -p "$(dirname "$PLIST_PATH")"
mkdir -p "$LOG_BASE"

# Resolve full PATH for the launchd env (bash + git + cargo discoverable)
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
        <string>${REFRESH_SCRIPT}</string>
    </array>

    <key>StartInterval</key>
    <integer>1800</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <key>StandardOutPath</key>
    <string>${LOG_BASE}/launchd-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_BASE}/launchd-stderr.log</string>

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
echo "first run will fire on load (RunAtLoad=true) then every 30 minutes"
echo "logs: $LOG_BASE/"
