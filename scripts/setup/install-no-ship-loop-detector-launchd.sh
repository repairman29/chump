#!/usr/bin/env bash
# RESILIENT-1573: install com.chump.no-ship-loop-detector launchd agent (every 15 min).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"
LABEL="com.chump.no-ship-loop-detector"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DAEMON_SCRIPT="$ROOT/scripts/coord/no-ship-loop-detector.sh"
INTERVAL_S="${CHUMP_NO_SHIP_LOOP_INTERVAL_S:-900}"
[[ -f "$DAEMON_SCRIPT" ]] || { echo "ERROR: $DAEMON_SCRIPT not found" >&2; exit 2; }
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.chump/logs" "$ROOT/.chump-locks" "$ROOT/.chump"
cat > "$PLIST_DEST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DAEMON_SCRIPT}</string>
        <string>tick</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.chump/logs/no-ship-loop-detector.out</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.chump/logs/no-ship-loop-detector.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/Users/${USER}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>CHUMP_AMBIENT_PATH</key>
        <string>${ROOT}/.chump-locks/ambient.jsonl</string>
        <key>REPO_ROOT</key>
        <string>${ROOT}</string>
    </dict>
</dict>
</plist>
PLISTEOF
plutil -lint "$PLIST_DEST" >/dev/null
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"
echo "Loaded ${LABEL} (interval=${INTERVAL_S}s)"
