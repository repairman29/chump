#!/usr/bin/env bash
# install-post-integration-prune-launchd.sh — INFRA-2138 (META-124/C10)
#
# Installs the chump-post-integration-prune daemon as a launchd LaunchAgent.
# The daemon tails ambient.jsonl for integration_cycle_shipped events and
# prunes per-gap branches on origin after a 24h grace window.
#
# Without this daemon, per-gap branches accumulate faster than cargo-target-
# reaper recovers disk. Disk-safety is the primary motivation (disk audit
# confirmed by infra-watcher, 2026-05-29).
#
# Plist design (INFRA-2182 anti-patterns applied):
#   KeepAlive=true     — daemon is long-lived (event listener)
#   RunAtLoad=true     — starts on boot / install (INFRA-2125 lesson)
#   ThrottleInterval=60 — prevents respawn-storm on ambient log rotation
#   ExitTimeOut=600    — NOT default 20s; background pruner sleeps for hours
#   SEPARATE StandardOutPath + StandardErrorPath — no truncation race
#   NO ProcessType=Background — wrong priority for git ops
#   WorkingDirectory   — main checkout, NOT a worktree
#
# Usage:
#   bash scripts/setup/install-post-integration-prune-launchd.sh             # install + start
#   bash scripts/setup/install-post-integration-prune-launchd.sh --check     # is it running?
#   bash scripts/setup/install-post-integration-prune-launchd.sh --uninstall # remove
#
# Cross-references: INFRA-2131 (companion: integrator installer),
#                   INFRA-2130 (emits the trigger event),
#                   INFRA-2125 (INFRA-2125-fixed plist pattern),
#                   INFRA-2182 (5 plist anti-patterns)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LABEL="dev.chump.post-integration-prune"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DAEMON="${REPO_ROOT}/scripts/ops/chump-post-integration-prune.sh"
LOG_DIR="${HOME}/.chump/logs"

cmd_check() {
    if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        echo "OK: $LABEL is registered with launchd"
        launchctl print "gui/$UID/$LABEL" \
            | grep -E "^[[:space:]]*(state|pid|last exit code)" \
            | head -3
        echo "    plist: $PLIST"
        echo "    out:   ${LOG_DIR}/post-integration-prune.out"
        echo "    err:   ${LOG_DIR}/post-integration-prune.err"
        exit 0
    else
        echo "FAIL: $LABEL is NOT registered with launchd"
        exit 1
    fi
}

cmd_uninstall() {
    if [[ -f "$PLIST" ]]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "uninstalled: $PLIST removed and launchd unloaded"
    else
        echo "(nothing to uninstall — $PLIST not present)"
    fi
    exit 0
}

case "${1:-install}" in
    --check)     cmd_check ;;
    --uninstall) cmd_uninstall ;;
esac

# INSTALL path
if [[ ! -f "$DAEMON" ]]; then
    echo "ERROR: daemon script not found: $DAEMON" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DAEMON}</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>60</integer>
    <key>ExitTimeOut</key>
    <integer>600</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/post-integration-prune.out</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/post-integration-prune.err</string>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
</dict>
</plist>
PLIST

# Idempotent reload
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "OK: ${LABEL} installed and loaded by launchd"
echo "    daemon:  ${DAEMON}"
echo "    plist:   ${PLIST}"
echo "    out:     ${LOG_DIR}/post-integration-prune.out"
echo "    err:     ${LOG_DIR}/post-integration-prune.err"
echo "    workdir: ${REPO_ROOT}"
echo "    grace:   \${CHUMP_POST_INTEGRATION_PRUNE_GRACE_H:-24}h (env-configurable)"
echo
echo "Verify:   bash ${BASH_SOURCE[0]} --check"
echo "Dry-run:  CHUMP_POST_INTEGRATION_PRUNE_DRY_RUN=1 bash ${DAEMON}"
echo "Logs:     tail -f ${LOG_DIR}/post-integration-prune.out"
