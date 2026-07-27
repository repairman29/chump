#!/usr/bin/env bash
# scripts/setup/install-node-refresh-systemd.sh — RESILIENT-200
#
# Install a systemd --user timer on a Linux fleet node that keeps the node's
# `chump` binary current with origin/main by running node-refresh-chump.sh on a
# cadence. This is the Linux equivalent of the macOS
# install-refresh-runner-binary-launchd.sh.
#
# PAUSE SAFETY: the timer runs binary-refresh ONLY. It does NOT enable, start,
# or reference any fleet-work unit (chumpd, mission loop, worker). A paused node
# (~/.chump/AUTONOMY_LEVEL=0) self-currents its binary and stays off.
#
# Cadence: 30 min (OnUnitActiveSec), first run 5 min after boot (OnBootSec).
#
# Linger: headless nodes need `loginctl enable-linger` so --user units run
# without an active login session. We attempt it and warn (not fail) if it needs
# privileges — an operator can run `sudo loginctl enable-linger $USER` once.
#
# Idempotent: re-running rewrites the units and re-enables the timer.
#
# Env:
#   CHUMP_NODE_REPO   passed through to the service (mirror to build from)
#   CHUMP_NODE_BIN    passed through to the service (install destination)
#   CADENCE_MIN       refresh cadence in minutes (default 30)

set -euo pipefail

CADENCE_MIN="${CADENCE_MIN:-30}"
UNIT_DIR="$HOME/.config/systemd/user"
SCRIPT_SRC=""
for candidate in \
    "${CHUMP_NODE_REPO:-}/scripts/ops/node-refresh-chump.sh" \
    "$HOME/chump-host/scripts/ops/node-refresh-chump.sh" \
    "$HOME/Projects/Chump/scripts/ops/node-refresh-chump.sh" \
    "$(dirname "$0")/../ops/node-refresh-chump.sh"; do
    if [[ -f "$candidate" ]]; then SCRIPT_SRC="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"; break; fi
done
if [[ -z "$SCRIPT_SRC" ]]; then
    echo "FATAL: cannot locate node-refresh-chump.sh (set CHUMP_NODE_REPO)" >&2
    exit 1
fi
chmod +x "$SCRIPT_SRC" 2>/dev/null || true
echo "refresh script: $SCRIPT_SRC"

mkdir -p "$UNIT_DIR"

# --- service (oneshot) -------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=chump node binary refresh (keep installed chump current with origin/main) — RESILIENT-200"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    [[ -n "${CHUMP_NODE_REPO:-}" ]] && echo "Environment=CHUMP_NODE_REPO=${CHUMP_NODE_REPO}"
    [[ -n "${CHUMP_NODE_BIN:-}" ]]  && echo "Environment=CHUMP_NODE_BIN=${CHUMP_NODE_BIN}"
    echo "ExecStart=/usr/bin/env bash ${SCRIPT_SRC}"
    echo "Nice=10"
} > "$UNIT_DIR/chump-node-refresh.service"

# --- timer -------------------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=chump node binary refresh timer (every ${CADENCE_MIN}m) — RESILIENT-200"
    echo ""
    echo "[Timer]"
    echo "OnBootSec=5min"
    echo "OnUnitActiveSec=${CADENCE_MIN}min"
    echo "Persistent=true"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
} > "$UNIT_DIR/chump-node-refresh.timer"

echo "wrote:"
echo "  $UNIT_DIR/chump-node-refresh.service"
echo "  $UNIT_DIR/chump-node-refresh.timer"

# --- linger (best-effort) ----------------------------------------------------
if command -v loginctl >/dev/null 2>&1; then
    if loginctl enable-linger "$USER" 2>/dev/null; then
        echo "linger enabled for $USER (timer runs without an active session)"
    else
        echo "WARN: could not enable linger — run once as operator: sudo loginctl enable-linger $USER" >&2
    fi
fi

# --- enable + start ----------------------------------------------------------
systemctl --user daemon-reload
systemctl --user enable --now chump-node-refresh.timer
echo ""
echo "=== timer status ==="
systemctl --user list-timers chump-node-refresh.timer --no-pager 2>/dev/null || true
echo ""
echo "Manual run:   systemctl --user start chump-node-refresh.service"
echo "Logs:         journalctl --user -u chump-node-refresh.service -n 50 --no-pager"
echo "Disable:      systemctl --user disable --now chump-node-refresh.timer"
