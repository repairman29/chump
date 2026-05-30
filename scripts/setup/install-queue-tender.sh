#!/usr/bin/env bash
# install-queue-tender.sh — META-243
#
# Installs (or removes) the com.chump.queue-tender launchd agent that runs
# scripts/coord/queue-tender-loop.sh tick every 300 seconds.
#
# Usage:
#   bash scripts/setup/install-queue-tender.sh install    # install + load
#   bash scripts/setup/install-queue-tender.sh uninstall  # unload + remove
#   bash scripts/setup/install-queue-tender.sh status     # print launchctl status
#   bash scripts/setup/install-queue-tender.sh check      # exit 0 if running, 1 if not
#
# Env knobs (read at install time):
#   CHUMP_QUEUE_TENDER_CADENCE_SEC             — StartInterval seconds (default 300)
#   CHUMP_QUEUE_TENDER_PARALLEL_REBASE         — max parallel rebase jobs (default 20)
#   CHUMP_QUEUE_TENDER_REBASE_HYSTERESIS_SEC   — hysteresis window in seconds (default 300)
#   CHUMP_SKIP_QUEUE_TENDER                    — set to 1 to install in kill-switch mode
#
# Path safety (INFRA-2302 lesson): the daemon script path is resolved from
# this installer's own location via dirname+realpath — never from CARGO_BIN
# or other env vars that may not survive a worktree reaping cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LABEL="com.chump.queue-tender"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DAEMON_SCRIPT="$(realpath "$SCRIPT_DIR/../coord/queue-tender-loop.sh")"
LOG_DIR="$HOME/.chump/logs"
LOG_OUT="$LOG_DIR/queue-tender.out.log"
LOG_ERR="$LOG_DIR/queue-tender.err.log"

CADENCE_SEC="${CHUMP_QUEUE_TENDER_CADENCE_SEC:-300}"
PARALLEL_REBASE="${CHUMP_QUEUE_TENDER_PARALLEL_REBASE:-20}"
HYSTERESIS_SEC="${CHUMP_QUEUE_TENDER_REBASE_HYSTERESIS_SEC:-300}"

# ── Helpers ───────────────────────────────────────────────────────────────────

_check_daemon_script() {
    if [[ ! -f "$DAEMON_SCRIPT" ]]; then
        echo "ERROR: daemon script not found at $DAEMON_SCRIPT" >&2
        echo "  META-243 must land before installing the queue-tender daemon." >&2
        exit 2
    fi
    if [[ ! -x "$DAEMON_SCRIPT" ]]; then
        chmod +x "$DAEMON_SCRIPT"
        echo "  chmod +x $DAEMON_SCRIPT"
    fi
}

_build_env_block() {
    local skip_block=""
    if [[ "${CHUMP_SKIP_QUEUE_TENDER:-0}" == "1" ]]; then
        skip_block="        <key>CHUMP_SKIP_QUEUE_TENDER</key>
        <string>1</string>"
    fi

    cat <<ENVEOF
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>CHUMP_QUEUE_TENDER_PARALLEL_REBASE</key>
        <string>${PARALLEL_REBASE}</string>
        <key>CHUMP_QUEUE_TENDER_REBASE_HYSTERESIS_SEC</key>
        <string>${HYSTERESIS_SEC}</string>
${skip_block}
ENVEOF
}

_write_plist() {
    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$LOG_DIR"

    local env_block
    env_block="$(_build_env_block)"

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
    <integer>${CADENCE_SEC}</integer>
    <!-- RunAtLoad=true fires one tick immediately on install to confirm the
         daemon works before the first StartInterval elapses (INFRA-351). -->
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
${env_block}
    </dict>
    <key>ThrottleInterval</key>
    <integer>60</integer>
</dict>
</plist>
PLISTEOF
    echo "Wrote $PLIST_DEST"
}

# ── Subcommands ───────────────────────────────────────────────────────────────

_cmd_install() {
    _check_daemon_script
    _write_plist

    # Unload prior version if present (idempotent).
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load "$PLIST_DEST"

    echo ""
    echo "Loaded launchd job ${LABEL}"
    echo "  Cadence:      every ${CADENCE_SEC}s (RunAtLoad=true)"
    echo "  Parallel cap: ${PARALLEL_REBASE} rebase jobs"
    echo "  Hysteresis:   ${HYSTERESIS_SEC}s per PR"
    echo "  Stdout:       ${LOG_OUT}"
    echo "  Stderr:       ${LOG_ERR}"
    echo "  Verify:       launchctl list | grep ${LABEL}"
    echo "  Uninstall:    bash $0 uninstall"
    echo "  Kill-switch:  CHUMP_SKIP_QUEUE_TENDER=1 bash $0 install"
    echo "  Doctrine:     docs/process/QUEUE_TENDER_DOCTRINE.md"
}

_cmd_uninstall() {
    if [[ ! -f "$PLIST_DEST" ]]; then
        echo "[queue-tender] $PLIST_DEST not found — nothing to uninstall"
        return 0
    fi
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    echo "[queue-tender] unloaded and removed $PLIST_DEST"
}

_cmd_status() {
    echo "=== queue-tender launchd status ==="
    echo "  plist:  $PLIST_DEST"
    echo "  script: $DAEMON_SCRIPT"
    echo ""
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
        echo "  launchctl: RUNNING"
        launchctl list 2>/dev/null | grep "$LABEL" || true
    else
        echo "  launchctl: NOT loaded"
    fi
    echo ""
    if [[ -f "$LOG_OUT" ]]; then
        echo "--- last 10 lines of stdout ---"
        tail -10 "$LOG_OUT" 2>/dev/null || true
    else
        echo "  (no stdout log yet)"
    fi
}

_cmd_check() {
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
        echo "[queue-tender] running (${LABEL} found in launchctl list)"
        return 0
    else
        echo "[queue-tender] NOT running (${LABEL} absent from launchctl list)"
        return 1
    fi
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

subcmd="${1:-install}"
case "$subcmd" in
    install)   _cmd_install ;;
    uninstall) _cmd_uninstall ;;
    status)    _cmd_status ;;
    check)     _cmd_check ;;
    *)
        echo "Usage: $0 install|uninstall|status|check" >&2
        exit 2
        ;;
esac
