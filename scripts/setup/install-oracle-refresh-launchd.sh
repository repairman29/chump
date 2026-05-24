#!/usr/bin/env bash
# scripts/setup/install-oracle-refresh-launchd.sh — META-088
#
# Installs the oracle-refresh launchd job — fires every 4 hours, spawns
# Opus to re-contemplate docs/process/THE_PATH.md. Auto-commits + auto-PRs
# on change; no-op when content hash matches.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/oracle-refresh.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.oracle-refresh.plist"

[[ -x "$SCRIPT" ]] || { echo "missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.oracle-refresh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.chump-locks/oracle-refresh.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/oracle-refresh.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

# Idempotent reinstall
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "[install-oracle-refresh-launchd] installed at $PLIST"
echo "[install-oracle-refresh-launchd] cadence: every 4h (14400s)"
echo "[install-oracle-refresh-launchd] logs: $REPO_ROOT/.chump-locks/oracle-refresh.log"
echo ""
echo "Manual run (immediate, bounded by CHUMP_ORACLE_WALL_BUDGET_S=30):"
echo "  bash $SCRIPT --force"
echo ""
echo "Bypass: CHUMP_ORACLE_DISABLED=1 in env"
echo ""
echo "Uninstall:"
echo "  launchctl unload $PLIST && rm $PLIST"
