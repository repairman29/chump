#!/usr/bin/env bash
# install-chump-integrator-launchd.sh — INFRA-2131 (META-124/C3)
#
# Installs the chump-integrator daemon as a launchd LaunchAgent so the
# META-124 integration-cycle machinery runs continuously on the host.
#
# The integrator polls for integration_cycle_ready events and drives
# multi-gap integration cycles end-to-end (merge, test, ship).
#
# Plist design (INFRA-2182 anti-patterns applied):
#   RunAtLoad=true     — starts on boot / install (INFRA-2125 lesson)
#   KeepAlive=true     — respawned if it exits (integration daemon is long-lived)
#   ThrottleInterval=60 — prevents respawn-storm on NATS flaps
#   ExitTimeOut=600    — NOT default 20s; kills mid-merge are catastrophic
#   SEPARATE StandardOutPath + StandardErrorPath — no truncation race
#   NO ProcessType=Background — wrong priority for git ops
#   WorkingDirectory   — main checkout, NOT a worktree
#
# Usage:
#   bash scripts/setup/install-chump-integrator-launchd.sh             # install + start
#   bash scripts/setup/install-chump-integrator-launchd.sh --check     # is it running?
#   bash scripts/setup/install-chump-integrator-launchd.sh --uninstall # remove
#
# Cross-references: INFRA-2102 (model: install-nats-server-launchd.sh),
#                   INFRA-2125 (RunAtLoad + StartInterval lessons),
#                   INFRA-2182 (5 plist anti-patterns),
#                   INFRA-2138 (companion: post-integration-prune daemon)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LABEL="dev.chump.integrator"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/.chump/logs"

# Locate the binary: PATH first, then ~/.local/bin fallback
locate_binary() {
    if command -v chump-integrator >/dev/null 2>&1; then
        command -v chump-integrator
    elif [[ -x "${HOME}/.local/bin/chump-integrator" ]]; then
        echo "${HOME}/.local/bin/chump-integrator"
    else
        echo ""
    fi
}

cmd_check() {
    if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        echo "OK: $LABEL is registered with launchd"
        launchctl print "gui/$UID/$LABEL" \
            | grep -E "^[[:space:]]*(state|pid|last exit code)" \
            | head -3
        echo "    plist: $PLIST"
        echo "    out:   ${LOG_DIR}/integrator.out"
        echo "    err:   ${LOG_DIR}/integrator.err"
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
INTEGRATOR_BIN="$(locate_binary)"
if [[ -z "$INTEGRATOR_BIN" ]]; then
    echo "ERROR: chump-integrator not found on PATH or ~/.local/bin/" >&2
    echo "  Build it with: cargo build --release -p chump-integrator" >&2
    echo "  Then copy: cp target/release/chump-integrator ~/.local/bin/" >&2
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
        <string>${INTEGRATOR_BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>60</integer>
    <key>ExitTimeOut</key>
    <integer>600</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/integrator.out</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/integrator.err</string>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
</dict>
</plist>
PLIST

# Idempotent reload
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "OK: ${LABEL} installed and loaded by launchd"
echo "    binary:  ${INTEGRATOR_BIN}"
echo "    plist:   ${PLIST}"
echo "    out:     ${LOG_DIR}/integrator.out"
echo "    err:     ${LOG_DIR}/integrator.err"
echo "    workdir: ${REPO_ROOT}"
echo
echo "Verify: bash ${BASH_SOURCE[0]} --check"
echo "Logs:   tail -f ${LOG_DIR}/integrator.out"
