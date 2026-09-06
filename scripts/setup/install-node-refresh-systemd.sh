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

# --- resolve the install destination (RESILIENT-378) -------------------------
# Bake CHUMP_NODE_BIN into the unit so the refresh installs where the FLEET's
# PATH actually resolves `chump`, not a fixed ~/.local/bin the PATH shadows
# (the RESILIENT-200 install-path bug that rotted closetjunky's fleet binary).
# Same precedence as node-refresh-chump.sh: explicit override → on-PATH chump
# (not the repo's own target build) → ~/.cargo/bin/chump → ~/.local/bin/chump.
if [[ -z "${CHUMP_NODE_BIN:-}" ]]; then
    _onpath="$(command -v chump 2>/dev/null || true)"
    if [[ -n "$_onpath" && "$_onpath" != *"/target/release/chump" && "$_onpath" != *"/target/debug/chump" ]]; then
        CHUMP_NODE_BIN="$_onpath"
    elif [[ -x "$HOME/.cargo/bin/chump" ]]; then
        CHUMP_NODE_BIN="$HOME/.cargo/bin/chump"
    else
        CHUMP_NODE_BIN="$HOME/.local/bin/chump"
    fi
fi
echo "install target: $CHUMP_NODE_BIN"

mkdir -p "$UNIT_DIR"

# --- service (oneshot) -------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=chump node binary refresh (keep installed chump current with origin/main) — RESILIENT-200"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    # RESILIENT-523: without an explicit TimeoutStartSec, systemd falls back to
    # DefaultTimeoutStartSec (90s system-wide default) — far shorter than even
    # the 30min limit that proved fatal to the macOS auto-deploy path on a cold
    # cargo build of the 190k+ LOC chump binary. node-refresh-chump.sh tries the
    # INFRA-3677 prebuilt-artifact pull first (seconds), but the local-build
    # fallback still needs headroom for a genuinely cold build. 2700s (45min)
    # sits comfortably above worst-case cold-build time while still bounding
    # a truly wedged run (network hang, deadlocked cargo) instead of running
    # forever.
    echo "TimeoutStartSec=2700"
    [[ -n "${CHUMP_NODE_REPO:-}" ]] && echo "Environment=CHUMP_NODE_REPO=${CHUMP_NODE_REPO}"
    [[ -n "${CHUMP_NODE_BIN:-}" ]]  && echo "Environment=CHUMP_NODE_BIN=${CHUMP_NODE_BIN}"
    # RESILIENT-1041 (fix a): a systemd --user timer starts with NO login
    # session and therefore no `gh auth login` state — the node-refresh script
    # can only see a real GH_TOKEN if this unit exports one. Bake in whatever
    # GH_TOKEN the *installing* environment has (operator's shell / bootstrap
    # secret), so the timer's `gh` calls are authenticated from the first run
    # instead of silently degrading to the raw-HEAD-fallback / cold-build
    # halt-class paths every single cycle.
    [[ -n "${GH_TOKEN:-}" ]] && echo "Environment=GH_TOKEN=${GH_TOKEN}"
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

# --- RESILIENT-523: node-deploy-lag-watchdog (loud signal on stall/timeout) --
# Linux/systemd counterpart of merge-deploy-lag-watchdog.sh (macOS-only). Runs
# every 5 min — much tighter than the refresh cadence — so a stalled or
# timed-out refresh surfaces fast instead of silently leaving the node on a
# stale binary (AC #2).
WATCHDOG_SRC=""
for candidate in \
    "$(dirname "$SCRIPT_SRC")/../coord/node-deploy-lag-watchdog.sh" \
    "${CHUMP_NODE_REPO:-}/scripts/coord/node-deploy-lag-watchdog.sh" \
    "$(dirname "$0")/../coord/node-deploy-lag-watchdog.sh"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then WATCHDOG_SRC="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"; break; fi
done

if [[ -n "$WATCHDOG_SRC" ]]; then
    chmod +x "$WATCHDOG_SRC" 2>/dev/null || true
    echo "watchdog script: $WATCHDOG_SRC"
    {
        echo "[Unit]"
        echo "Description=chump node deploy-lag watchdog (loud signal on stalled/timed-out refresh) — RESILIENT-523"
        echo "After=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=oneshot"
        [[ -n "${CHUMP_NODE_REPO:-}" ]] && echo "Environment=CHUMP_REPO_ROOT=${CHUMP_NODE_REPO}"
        [[ -n "${CHUMP_NODE_BIN:-}" ]]  && echo "Environment=CHUMP_NODE_BIN=${CHUMP_NODE_BIN}"
        echo "ExecStart=/usr/bin/env bash ${WATCHDOG_SRC}"
        echo "Nice=10"
    } > "$UNIT_DIR/chump-node-deploy-lag-watchdog.service"
    {
        echo "[Unit]"
        echo "Description=chump node deploy-lag watchdog timer (every 5m) — RESILIENT-523"
        echo ""
        echo "[Timer]"
        echo "OnBootSec=5min"
        echo "OnUnitActiveSec=5min"
        echo "Persistent=true"
        echo ""
        echo "[Install]"
        echo "WantedBy=timers.target"
    } > "$UNIT_DIR/chump-node-deploy-lag-watchdog.timer"
else
    echo "WARN: node-deploy-lag-watchdog.sh not found — skipping watchdog install" >&2
fi

echo "wrote:"
echo "  $UNIT_DIR/chump-node-refresh.service"
echo "  $UNIT_DIR/chump-node-refresh.timer"
[[ -n "$WATCHDOG_SRC" ]] && echo "  $UNIT_DIR/chump-node-deploy-lag-watchdog.service" && echo "  $UNIT_DIR/chump-node-deploy-lag-watchdog.timer"

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
[[ -n "$WATCHDOG_SRC" ]] && systemctl --user enable --now chump-node-deploy-lag-watchdog.timer
echo ""
echo "=== timer status ==="
systemctl --user list-timers chump-node-refresh.timer --no-pager 2>/dev/null || true
[[ -n "$WATCHDOG_SRC" ]] && systemctl --user list-timers chump-node-deploy-lag-watchdog.timer --no-pager 2>/dev/null || true
echo ""
echo "Manual run:   systemctl --user start chump-node-refresh.service"
echo "Logs:         journalctl --user -u chump-node-refresh.service -n 50 --no-pager"
echo "Watchdog run: systemctl --user start chump-node-deploy-lag-watchdog.service"
echo "Watchdog log: journalctl --user -u chump-node-deploy-lag-watchdog.service -n 50 --no-pager"
echo "Disable:      systemctl --user disable --now chump-node-refresh.timer"
