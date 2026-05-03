#!/usr/bin/env bash
# Install launchd plist that runs scripts/eval/soak-checkpoint.sh every
# 4 hours. Pairs with the 72h-soak gate item in docs/strategy/ROADMAP.md
# ("Architecture vs proof → Overnight / 72h soak").
#
# Usage:
#   bash scripts/setup/install-soak-checkpoint-launchd.sh   # install + load
#   launchctl unload ~/Library/LaunchAgents/dev.chump.soak-checkpoint.plist
#                                                            # to stop
#
# Env knobs (read from your shell at install time):
#   CHUMP_WEB_PORT  — default 3000
#   CHUMP_WEB_HOST  — default 127.0.0.1
#   CHUMP_WEB_TOKEN — bearer token for /api/stack-status (optional)
#   SOAK_INTERVAL_HOURS — default 4 (must be a divisor of 24 for clean alignment)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PORT="${CHUMP_WEB_PORT:-3000}"
HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
INTERVAL_H="${SOAK_INTERVAL_HOURS:-4}"
INTERVAL_S=$((INTERVAL_H * 3600))

LABEL="dev.chump.soak-checkpoint"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT="$ROOT/scripts/eval/soak-checkpoint.sh"
LOG_OUT="/tmp/chump-soak-checkpoint.out.log"
LOG_ERR="/tmp/chump-soak-checkpoint.err.log"

if [[ ! -x "$SCRIPT" ]]; then
    chmod +x "$SCRIPT"
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Build optional token line
TOKEN_LINE=""
if [[ -n "$TOKEN" ]]; then
    TOKEN_LINE="
        <key>CHUMP_WEB_TOKEN</key>
        <string>${TOKEN}</string>"
fi

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
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CHUMP_WEB_HOST</key>
        <string>${HOST}</string>
        <key>CHUMP_WEB_PORT</key>
        <string>${PORT}</string>${TOKEN_LINE}
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST}"

# Reload (unload then load)
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "✓ Loaded launchd job ${LABEL}"
echo "  Cadence: every ${INTERVAL_H}h"
echo "  Stdout:  ${LOG_OUT}"
echo "  Stderr:  ${LOG_ERR}"
echo "  Verify:  launchctl list | grep ${LABEL}"
echo "  Disable: launchctl unload ${PLIST}"
echo ""
echo "Each tick appends a checkpoint to docs/SOAK_72H_LOG.md."
echo "After 72h (18 ticks at 4h cadence), the soak run is complete —"
echo "review the log, append a verdict, and check the roadmap item."
