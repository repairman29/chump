#!/usr/bin/env bash
# install-nats-server-launchd.sh — INFRA-2102
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
# Usage:
#   bash scripts/setup/install-nats-server-launchd.sh             # install + start
#   bash scripts/setup/install-nats-server-launchd.sh --check     # is it running?
#   bash scripts/setup/install-nats-server-launchd.sh --uninstall # remove
#
# Companion runbook: docs/strategy/NATS_A2A_DEMO_2026-05-28.md
# Persist CHUMP_NATS_URL in shell rc: see runbook.

set -euo pipefail

PLIST_NAME="com.chump.nats-server.plist"
PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="com.chump.nats-server"
NATS_DIR="$HOME/.chump/nats"
LOG_FILE="$NATS_DIR/server.log"

cmd_check() {
    if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        echo "OK: $LABEL is registered with launchd"
        launchctl print "gui/$UID/$LABEL" | grep -E "^[[:space:]]*(state|pid|last exit code)" | head -3
        echo
        if lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -q ':4222 '; then
            echo "OK: port 4222 listening"
        else
            echo "WARN: launchd has $LABEL but port 4222 not listening — check $LOG_FILE"
        fi
        exit 0
    else
        echo "FAIL: $LABEL is NOT registered with launchd"
        exit 1
    fi
}

cmd_uninstall() {
    if [ -f "$PLIST" ]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "uninstalled: $PLIST removed and launchd unloaded"
    else
        echo "(nothing to uninstall — $PLIST not present)"
    fi
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
    echo "Persist CHUMP_NATS_URL in your shell rc:"
    echo "    echo 'export CHUMP_NATS_URL=nats://localhost:4222' >> ~/.zshrc"
    echo "    source ~/.zshrc"
    echo
    echo "Verify chump-coord can talk to it:"
    echo "    CHUMP_NATS_URL=nats://localhost:4222 chump-coord ping"
else
    echo "FAIL: launchd loaded $PLIST but port 4222 not listening — check $LOG_FILE" >&2
    exit 1
fi
