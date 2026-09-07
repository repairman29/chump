#!/usr/bin/env bash
# scripts/setup/install-fleet-health-sentinel.sh — RESILIENT-1052
#
# Install the anti-Memento fleet-health sentinel as a systemd --user timer on
# an owned Linux node (the same mechanism node-refresh uses on the Oracle
# nodes). Mirrors install-node-refresh-systemd.sh.
#
# The sentinel runs --local every CADENCE_MIN minutes: scan+heal this node's
# failed chump units, re-enable inactive healers, write its heartbeat. Because
# the sentinel RE-ENABLES required healers every pass, a node cannot sit with
# inactive drift-protection the way cuphead/mugman did on 2026-09-07 — the
# healers converge back to active on the next tick (durable activation).
#
# Idempotent: re-running rewrites the units and re-enables the timer.
#
# Env:
#   CHUMP_NODE_REPO   repo root to run the sentinel from (default: autodetect)
#   CADENCE_MIN       sentinel cadence in minutes (default 5)
#   CHUMP_FLEET_SERVER_URL  passed through (best-effort heartbeat POST)

set -euo pipefail

CADENCE_MIN="${CADENCE_MIN:-5}"
UNIT_DIR="$HOME/.config/systemd/user"

SCRIPT_SRC=""
for candidate in \
    "${CHUMP_NODE_REPO:-}/scripts/ops/fleet-health-sentinel.sh" \
    "$HOME/chump/scripts/ops/fleet-health-sentinel.sh" \
    "$HOME/chump-host/scripts/ops/fleet-health-sentinel.sh" \
    "$(dirname "$0")/../ops/fleet-health-sentinel.sh"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        SCRIPT_SRC="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"; break
    fi
done
[[ -z "$SCRIPT_SRC" ]] && { echo "FATAL: cannot locate fleet-health-sentinel.sh (set CHUMP_NODE_REPO)" >&2; exit 1; }
chmod +x "$SCRIPT_SRC" 2>/dev/null || true
REPO_ROOT="$(cd "$(dirname "$SCRIPT_SRC")/../.." && pwd)"
echo "sentinel script: $SCRIPT_SRC"
echo "repo root:       $REPO_ROOT"

mkdir -p "$UNIT_DIR"

{
    echo "[Unit]"
    echo "Description=chump anti-Memento fleet-health sentinel (scan+heal failed units + inactive healers) — RESILIENT-1052"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "TimeoutStartSec=300"
    echo "WorkingDirectory=${REPO_ROOT}"
    echo "Environment=CHUMP_STATE_DIR=${CHUMP_STATE_DIR:-$HOME/.chump}"
    [[ -n "${CHUMP_FLEET_SERVER_URL:-}" ]] && echo "Environment=CHUMP_FLEET_SERVER_URL=${CHUMP_FLEET_SERVER_URL}"
    echo "ExecStart=/usr/bin/env bash ${SCRIPT_SRC} --local"
    echo "Nice=10"
} > "$UNIT_DIR/chump-fleet-health-sentinel.service"

{
    echo "[Unit]"
    echo "Description=chump fleet-health sentinel timer (every ${CADENCE_MIN}m) — RESILIENT-1052"
    echo ""
    echo "[Timer]"
    echo "OnBootSec=2min"
    echo "OnUnitActiveSec=${CADENCE_MIN}min"
    echo "Persistent=true"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
} > "$UNIT_DIR/chump-fleet-health-sentinel.timer"

echo "wrote:"
echo "  $UNIT_DIR/chump-fleet-health-sentinel.service"
echo "  $UNIT_DIR/chump-fleet-health-sentinel.timer"

if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$USER" 2>/dev/null \
        && echo "linger enabled for $USER" \
        || echo "WARN: could not enable linger — run once: sudo loginctl enable-linger $USER" >&2
fi

systemctl --user daemon-reload
systemctl --user enable --now chump-fleet-health-sentinel.timer
echo ""
echo "=== timer status ==="
systemctl --user list-timers chump-fleet-health-sentinel.timer --no-pager 2>/dev/null || true
echo ""
echo "Manual run:   systemctl --user start chump-fleet-health-sentinel.service"
echo "Logs:         journalctl --user -u chump-fleet-health-sentinel.service -n 50 --no-pager"
echo "Disable:      systemctl --user disable --now chump-fleet-health-sentinel.timer"
