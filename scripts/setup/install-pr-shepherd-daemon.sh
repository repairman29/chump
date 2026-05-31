#!/usr/bin/env bash
# scripts/setup/install-pr-shepherd-daemon.sh — META-192
#
# Idempotently installs the launchd agent that runs pr-shepherd-daemon.sh
# every 60 seconds (StartInterval: 60).
#
# The daemon classifies all open PRs into 8 states (BEHIND/MERGEABLE/ARMED/
# DIRTY/BLOCKED_GREEN/BLOCKED_REAL_FAIL/UNKNOWN/CONFLICTING), auto-rebases
# BEHIND PRs, arms auto-merge on BLOCKED_GREEN, and files follow-up gaps on
# BLOCKED_REAL_FAIL. See META-180 through META-184 for the full story.
#
# Usage:
#   bash scripts/setup/install-pr-shepherd-daemon.sh        # install + load
#   launchctl unload ~/Library/LaunchAgents/com.chump.pr-shepherd.plist
#
# Does NOT start the daemon if already loaded — unloads first to pick up
# any plist changes, then loads fresh (idempotent pattern from INFRA-1779).
#
# Env knobs (read at install time):
#   CHUMP_PR_SHEPHERD_DRY_RUN           — set to 1 to install in dry-run mode
#   CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK — override max rebases per tick

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve main worktree so the plist path survives worktree reaping (INFRA-451).
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"

LABEL="com.chump.pr-shepherd"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DAEMON_SCRIPT="$ROOT/scripts/coord/pr-shepherd-daemon.sh"
LOG_OUT="$HOME/.chump/logs/pr-shepherd.out"
LOG_ERR="$HOME/.chump/logs/pr-shepherd.err"
INTERVAL_S=60   # every 60 seconds — matches META-181 default tick

if [[ ! -f "$DAEMON_SCRIPT" ]]; then
    echo "ERROR: $DAEMON_SCRIPT not found — META-180/META-181 must land first." >&2
    exit 2
fi
[[ -x "$DAEMON_SCRIPT" ]] || chmod +x "$DAEMON_SCRIPT"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.chump/logs"

# Build optional env var block for dry-run mode
DRY_RUN_KEY=""
if [[ -n "${CHUMP_PR_SHEPHERD_DRY_RUN:-}" ]]; then
    DRY_RUN_KEY="        <key>CHUMP_PR_SHEPHERD_DRY_RUN</key>
        <string>1</string>"
fi

MAX_REBASES_KEY=""
if [[ -n "${CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK:-}" ]]; then
    MAX_REBASES_KEY="        <key>CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK</key>
        <string>${CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK}</string>"
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
        <string>${DAEMON_SCRIPT}</string>
        <string>tick</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <!-- RunAtLoad=true: exercises the daemon immediately on install so
         "did the plist land correctly?" is answered at install time, not
         60 seconds later (INFRA-351 lesson). -->
    <key>RunAtLoad</key>
    <true/>
    <!-- KeepAlive=false: pr-shepherd-daemon.sh tick is a single-shot script.
         launchd re-launches it every StartInterval seconds. -->
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- gh CLI needs HOME for auth token; PATH for git + python3 (INFRA-802). -->
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
${DRY_RUN_KEY}
${MAX_REBASES_KEY}
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST}"

# Unload first (idempotent — fails silently if not loaded).
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "Loaded launchd job ${LABEL}"
echo "  Cadence:  every ${INTERVAL_S}s (RunAtLoad=true, KeepAlive=false)"
echo "  Stdout:   ${LOG_OUT}"
echo "  Stderr:   ${LOG_ERR}"
echo "  Verify:   launchctl list | grep ${LABEL}"
echo "  Disable:  launchctl unload ${PLIST}"
echo "  Dry-run:  CHUMP_PR_SHEPHERD_DRY_RUN=1 bash $0"
