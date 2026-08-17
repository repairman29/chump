#!/usr/bin/env bash
# install-nats-server-launchd.sh — INFRA-2102 / INFRA-2471
#
# Installs the NATS server as a launchd LaunchAgent so the chump-coord
# A2A substrate has a always-on broker on localhost:4222 with JetStream.
#
# Why: chump-coord, chump-messaging, FLEET-034 NATS push routing,
# atomic-CAS gap claims, work-board subtasks, and the META-061 A2A
# Layer 1a-4 primitives all assume a reachable NATS broker. Until this
# script ran 2026-05-28, the broker was unset in production and the
# entire substrate fell through to the file-fallback path. After this
# script runs once: NATS is always on, the substrate works end-to-end.
#
# INFRA-2471: the original version of this script only *printed* the
# CHUMP_NATS_URL export as advice — it never actually set it anywhere, so
# every process spawned after the broker came up (workers, curators,
# `chump-coord assign`) still saw an unset var and silently fell back to
# the file-fallback path. The broker was up and idle for 2 days before
# anyone noticed no client had ever connected. This version actually SETS
# the var three ways so it's live for both the current session and every
# future login: (1) `launchctl setenv` for the current GUI session, (2) a
# reboot-persistent `com.chump.fleet-setenv` LaunchAgent (RunAtLoad) that
# re-applies the setenv on every login, and (3) an idempotent append to
# the shell rc for interactive/non-GUI shells.
#
# Usage:
#   bash scripts/setup/install-nats-server-launchd.sh             # install + start
#   bash scripts/setup/install-nats-server-launchd.sh --check     # is it running?
#   bash scripts/setup/install-nats-server-launchd.sh --uninstall # remove
#
# Companion runbook: docs/strategy/NATS_A2A_DEMO_2026-05-28.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.chump.nats-server.plist"
PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="com.chump.nats-server"
NATS_DIR="$HOME/.chump/nats"
LOG_FILE="$NATS_DIR/server.log"
NATS_URL_VALUE="nats://127.0.0.1:4222"

SETENV_LABEL="com.chump.fleet-setenv"
SETENV_PLIST_TEMPLATE="$SCRIPT_DIR/com.chump.fleet-setenv.plist"
SETENV_PLIST="$HOME/Library/LaunchAgents/${SETENV_LABEL}.plist"

# ── install_setenv_daemon: reboot-persistent CHUMP_NATS_URL propagation ───────
# launchd `setenv` only affects the *current* login session's environment
# domain — it does not persist across reboot/logout on its own. A tiny
# RunAtLoad LaunchAgent that re-issues the setenv on every login closes that
# gap without requiring the operator to remember to re-run this script.
install_setenv_daemon() {
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s#__NATS_URL__#${NATS_URL_VALUE}#g" "$SETENV_PLIST_TEMPLATE" > "$SETENV_PLIST"
    launchctl unload "$SETENV_PLIST" 2>/dev/null || true
    launchctl load "$SETENV_PLIST"
}

# ── persist_shell_rc: idempotent export for interactive/non-GUI shells ────────
persist_shell_rc() {
    local rc="$1"
    [[ -f "$rc" ]] || touch "$rc"
    if ! grep -q "CHUMP_NATS_URL" "$rc" 2>/dev/null; then
        {
            echo ""
            echo "# INFRA-2471: chump A2A mesh broker (set by install-nats-server-launchd.sh)"
            echo "export CHUMP_NATS_URL=${NATS_URL_VALUE}"
        } >> "$rc"
    fi
}

cmd_check() {
    local rc=0
    if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        echo "OK: $LABEL is registered with launchd"
        launchctl print "gui/$UID/$LABEL" | grep -E "^[[:space:]]*(state|pid|last exit code)" | head -3
        echo
        if lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -q ':4222 '; then
            echo "OK: port 4222 listening"
        else
            echo "WARN: launchd has $LABEL but port 4222 not listening — check $LOG_FILE"
            rc=1
        fi
    else
        echo "FAIL: $LABEL is NOT registered with launchd"
        rc=1
    fi

    if launchctl print "gui/$UID/$SETENV_LABEL" >/dev/null 2>&1; then
        echo "OK: $SETENV_LABEL is registered with launchd (reboot-persistent env)"
    else
        echo "FAIL: $SETENV_LABEL is NOT registered with launchd — CHUMP_NATS_URL will not survive reboot"
        rc=1
    fi

    local env_val
    env_val="$(launchctl getenv CHUMP_NATS_URL 2>/dev/null || true)"
    if [[ -n "$env_val" ]]; then
        echo "OK: CHUMP_NATS_URL is set in the launchd GUI session: $env_val"
    else
        echo "FAIL: CHUMP_NATS_URL is NOT set via launchctl setenv — new processes won't see it"
        rc=1
    fi

    exit "$rc"
}

cmd_uninstall() {
    if [ -f "$PLIST" ]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "uninstalled: $PLIST removed and launchd unloaded"
    else
        echo "(nothing to uninstall — $PLIST not present)"
    fi
    if [ -f "$SETENV_PLIST" ]; then
        launchctl unload "$SETENV_PLIST" 2>/dev/null || true
        rm -f "$SETENV_PLIST"
        echo "uninstalled: $SETENV_PLIST removed and launchd unloaded"
    fi
    launchctl unsetenv CHUMP_NATS_URL 2>/dev/null || true
    exit 0
}

case "${1:-install}" in
    --check) cmd_check ;;
    --uninstall) cmd_uninstall ;;
esac

# INSTALL path
if ! command -v nats-server >/dev/null 2>&1; then
    echo "nats-server not on PATH — install via:" >&2
    echo "  brew install nats-server" >&2
    exit 1
fi
NATS_BIN="$(command -v nats-server)"

mkdir -p "$HOME/Library/LaunchAgents" "$NATS_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NATS_BIN</string>
    <string>--port</string><string>4222</string>
    <string>--jetstream</string>
    <string>--store_dir</string><string>$NATS_DIR</string>
    <string>-l</string><string>$LOG_FILE</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$NATS_DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$NATS_DIR/launchd.err</string>
</dict>
</plist>
EOF

# Reload if already loaded (idempotent)
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 2

if lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -q ':4222 '; then
    echo "OK: NATS listening on port 4222 (managed by launchd)"
    echo "    plist: $PLIST"
    echo "    log: $LOG_FILE"
    echo "    JetStream store: $NATS_DIR"
    echo

    # INFRA-2471: actually SET CHUMP_NATS_URL, don't just print advice.
    launchctl setenv CHUMP_NATS_URL "$NATS_URL_VALUE"
    echo "OK: launchctl setenv CHUMP_NATS_URL=$NATS_URL_VALUE (current GUI session)"

    install_setenv_daemon
    echo "OK: installed $SETENV_LABEL LaunchAgent (RunAtLoad, reboot-persistent setenv)"

    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        persist_shell_rc "$rc"
    done
    echo "OK: appended 'export CHUMP_NATS_URL=$NATS_URL_VALUE' to ~/.zshrc and ~/.bashrc (idempotent)"
    echo
    echo "CHUMP_NATS_URL is now live for this session, future logins, and new shells."
    echo "Verify chump-coord can talk to it:"
    echo "    chump-coord ping"
else
    echo "FAIL: launchd loaded $PLIST but port 4222 not listening — check $LOG_FILE" >&2
    exit 1
fi
