#!/usr/bin/env bash
# scripts/setup/install-free-tier-refresh-systemd.sh — CREDIBLE-185
#
# Install a systemd --user timer on a Linux fleet node (e.g. closetjunky) that
# keeps the node's FREE-TIER cascade current + validated in ~/.chump/providers.env
# by running free-tier-refresh.sh on a cadence. Sibling of
# install-node-refresh-systemd.sh (binary refresh) — same conventions: --user
# timer, linger, idempotent, ambient events. Kept separate because the two have
# different cadences and one refreshing config must not depend on the other's
# cargo build.
#
# PAUSE SAFETY: the timer runs cascade-config refresh ONLY. It never enables,
# starts, or references any fleet-work unit and never touches AUTONOMY_LEVEL.
#
# Cadence: daily (OnUnitActiveSec=1d, first run 3 min after boot). The cascade
# rarely changes; daily matches helsinki's old daily provider refresh.
#
# Idempotent: re-running rewrites the units and re-enables the timer.
#
# Env:
#   CHUMP_STATE_DIR   passed to the service (dir holding providers.env)
#   CADENCE           systemd time span for OnUnitActiveSec (default: 1d)

set -euo pipefail

CADENCE="${CADENCE:-1d}"
UNIT_DIR="$HOME/.config/systemd/user"
SCRIPT_SRC=""
for candidate in \
    "${CHUMP_NODE_REPO:-}/scripts/ops/free-tier-refresh.sh" \
    "$HOME/chump-host/scripts/ops/free-tier-refresh.sh" \
    "$HOME/chump-repo/scripts/ops/free-tier-refresh.sh" \
    "$HOME/Projects/Chump/scripts/ops/free-tier-refresh.sh" \
    "$(dirname "$0")/../ops/free-tier-refresh.sh"; do
    if [[ -f "$candidate" ]]; then SCRIPT_SRC="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"; break; fi
done
if [[ -z "$SCRIPT_SRC" ]]; then
    echo "FATAL: cannot locate free-tier-refresh.sh (set CHUMP_NODE_REPO)" >&2
    exit 1
fi
chmod +x "$SCRIPT_SRC" 2>/dev/null || true
echo "refresh script: $SCRIPT_SRC"

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
echo "state dir: $STATE_DIR"

mkdir -p "$UNIT_DIR"

# --- service (oneshot) -------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=chump free-tier cascade refresh (keep CHUMP_FREE_TIER_PROVIDERS validated + \$0) — CREDIBLE-185"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "Environment=CHUMP_STATE_DIR=${STATE_DIR}"
    echo "ExecStart=/usr/bin/env bash ${SCRIPT_SRC}"
    echo "Nice=10"
} > "$UNIT_DIR/chump-free-tier-refresh.service"

# --- timer -------------------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=chump free-tier cascade refresh timer (every ${CADENCE}) — CREDIBLE-185"
    echo ""
    echo "[Timer]"
    echo "OnBootSec=3min"
    echo "OnUnitActiveSec=${CADENCE}"
    echo "Persistent=true"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
} > "$UNIT_DIR/chump-free-tier-refresh.timer"

echo "wrote:"
echo "  $UNIT_DIR/chump-free-tier-refresh.service"
echo "  $UNIT_DIR/chump-free-tier-refresh.timer"

# --- linger (best-effort) ----------------------------------------------------
if command -v loginctl >/dev/null 2>&1; then
    if loginctl enable-linger "$USER" 2>/dev/null; then
        echo "linger enabled for $USER (timer runs without an active session)"
    else
        echo "WARN: could not enable linger — run once as operator: sudo loginctl enable-linger $USER" >&2
    fi
fi

# --- enable + start (also runs the refresh once now) -------------------------
systemctl --user daemon-reload
systemctl --user enable --now chump-free-tier-refresh.timer
systemctl --user start chump-free-tier-refresh.service || true
echo ""
echo "=== timer status ==="
systemctl --user list-timers chump-free-tier-refresh.timer --no-pager 2>/dev/null || true
echo ""
echo "Manual run:   systemctl --user start chump-free-tier-refresh.service"
echo "Logs:         journalctl --user -u chump-free-tier-refresh.service -n 50 --no-pager"
echo "Disable:      systemctl --user disable --now chump-free-tier-refresh.timer"
