#!/data/data/com.termux/files/usr/bin/bash
# scripts/setup/install-free-tier-refresh-runit.sh — CREDIBLE-185
#
# Install a runit service on the Pixel (Termux) that keeps the node's FREE-TIER
# cascade current + validated in ~/.chump/providers.env by running
# free-tier-refresh.sh once a day. The Pixel has NO systemd — its organs are
# runit services under $PREFIX/var/service (node-heartbeat, pixel-worker, ...),
# so this is the runit counterpart of install-free-tier-refresh-systemd.sh.
#
# runit has no timers, so the service is a supervised loop: refresh, then
# sleep a day. Mirrors the existing organs' run-script conventions
# (Termux sh shebang, exec 2>&1, CHUMP_* exports, termux-wake-lock).
#
# PAUSE SAFETY: refreshes cascade config ONLY. Never touches AUTONOMY_LEVEL,
# never starts fleet work. Does NOT touch node-heartbeat, postgres, nats-bridge,
# pixel-worker, or the (retired) discord-gateway.
#
# Idempotent: re-running rewrites the run script and re-links the service.

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
SVC_ROOT="$PREFIX/var/service"
SVC_NAME="free-tier-refresh"
SVC_DIR="$SVC_ROOT/$SVC_NAME"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME_DIR/.chump}"

# locate the tracked refresh script (repo checkout on the Pixel is ~/chump-repo)
SCRIPT_SRC=""
for candidate in \
    "${CHUMP_NODE_REPO:-}/scripts/ops/free-tier-refresh.sh" \
    "$HOME_DIR/chump-repo/scripts/ops/free-tier-refresh.sh" \
    "$HOME_DIR/chump/scripts/ops/free-tier-refresh.sh" \
    "$(dirname "$0")/../ops/free-tier-refresh.sh"; do
    if [[ -f "$candidate" ]]; then SCRIPT_SRC="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"; break; fi
done
if [[ -z "$SCRIPT_SRC" ]]; then
    echo "FATAL: cannot locate free-tier-refresh.sh (set CHUMP_NODE_REPO)" >&2
    exit 1
fi
chmod +x "$SCRIPT_SRC" 2>/dev/null || true
echo "refresh script: $SCRIPT_SRC"
echo "state dir:      $STATE_DIR"
echo "service dir:    $SVC_DIR"

SLEEP_SECS="${SLEEP_SECS:-86400}"   # daily

mkdir -p "$SVC_DIR"

# --- run script (supervised daily loop) --------------------------------------
cat > "$SVC_DIR/run" <<RUN
#!$PREFIX/bin/sh
exec 2>&1
export CHUMP_STATE_DIR=$STATE_DIR PATH=$PREFIX/bin:\$PATH
termux-wake-lock 2>/dev/null || true
while :; do
    bash $SCRIPT_SRC || true
    sleep $SLEEP_SECS
done
RUN
chmod +x "$SVC_DIR/run"

# --- log service (optional, mirrors other organs if svlogd present) ----------
if command -v svlogd >/dev/null 2>&1; then
    mkdir -p "$SVC_DIR/log" "$HOME_DIR/.chump/free-tier-refresh-logs"
    cat > "$SVC_DIR/log/run" <<LOGRUN
#!$PREFIX/bin/sh
exec svlogd -tt $HOME_DIR/.chump/free-tier-refresh-logs
LOGRUN
    chmod +x "$SVC_DIR/log/run"
fi

echo "wrote $SVC_DIR/run"

# --- register with runsv (runit auto-supervises anything under SVC_ROOT) -----
if command -v sv >/dev/null 2>&1; then
    # give runsvdir a moment to pick up the new dir, then ensure it's up
    sleep 2
    sv up "$SVC_NAME" 2>/dev/null || sv up "$SVC_DIR" 2>/dev/null || true
    echo ""
    echo "=== service status ==="
    sv status "$SVC_NAME" 2>/dev/null || sv status "$SVC_DIR" 2>/dev/null || true
else
    echo "WARN: 'sv' not found; is runit installed? (pkg install runit)" >&2
fi
echo ""
echo "Manual run:   bash $SCRIPT_SRC"
echo "Status:       sv status $SVC_NAME"
echo "Restart:      sv restart $SVC_NAME"
echo "Stop:         sv down $SVC_NAME"
