#!/usr/bin/env bash
# scripts/setup/install-fleet-server-node.sh — RESILIENT-1046
#
# Install the chump-fleet-server audit/dashboard organ on a Linux fleet node as
# a DURABLE systemd --user service, plus a refresh timer that keeps its binary
# current with green-main by PULLING the prebuilt artifact (never building on
# the node). This is the Linux/owned-iron equivalent of the macOS-only
# scripts/setup/install-fleet-server.sh (which is launchd + builds locally) and
# the "see everything out" / audit-OUT half of the operating covenant: the
# fleet's state becomes queryable over an HTTP API instead of by SSH-ing boxes.
#
# WHY this exists: install-fleet-server.sh is launchd + `cargo build` — it only
# works on the Mac and would starve a 2-core Oracle node. The
# chump-fleet-server.service unit shipped for helsinki is host-rewritten by
# install-helsinki-atc.sh into a SYSTEM (root) unit that runs the binary out of
# the working tree's target/release — i.e. it depends on a local build existing.
# Neither gives a fresh owned-iron node the server automatically. This installer
# does: a --user service on the fleet-owner account + a pull-driven refresh
# timer, mirroring the node-refresh-chump.sh / install-node-refresh-systemd.sh
# pair (RESILIENT-200/INFRA-3677) that already self-sustains the worker binary.
#
# Installs (all under ~/.config/systemd/user):
#   chump-fleet-server.service          long-running (Type=simple, Restart=always)
#   chump-fleet-server-refresh.service  oneshot → node-refresh-fleet-server.sh
#   chump-fleet-server-refresh.timer    every CADENCE_MIN (default 30m)
#
# Idempotent: re-running rewrites the units, re-runs the pull, re-enables both.
#
# Usage:
#   scripts/setup/install-fleet-server-node.sh              # install + start
#   scripts/setup/install-fleet-server-node.sh --uninstall  # stop + remove
#
# Env:
#   CHUMP_NODE_REPO            repo checkout the server reads (.chump/, .chump-locks/)
#   CHUMP_FLEET_SERVER_BIN     install destination (default ~/.local/bin/chump-fleet-server)
#   CHUMP_FLEET_SERVER_PORT    bind port (default 7070)
#   CHUMP_FLEET_SERVER_BIND    bind address (default 127.0.0.1; a tailnet IP exposes
#                              the authed create/audit API — see main.rs caveat)
#   CHUMP_PROVIDERS_ENV        creds sourced by the service (default ~/.chump/providers.env)
#   CADENCE_MIN                refresh cadence in minutes (default 30)

set -euo pipefail

UNIT_DIR="$HOME/.config/systemd/user"
CADENCE_MIN="${CADENCE_MIN:-30}"
FLEET_UNIT="chump-fleet-server.service"
REFRESH_UNIT="chump-fleet-server-refresh"

# --- locate the refresh script (source of truth) -----------------------------
REFRESH_SRC=""
for c in \
    "${CHUMP_NODE_REPO:-}/scripts/ops/node-refresh-fleet-server.sh" \
    "$HOME/chump-host/scripts/ops/node-refresh-fleet-server.sh" \
    "$HOME/Projects/Chump/scripts/ops/node-refresh-fleet-server.sh" \
    "$HOME/chump/scripts/ops/node-refresh-fleet-server.sh" \
    "$(dirname "$0")/../ops/node-refresh-fleet-server.sh"; do
    [[ -n "$c" && -f "$c" ]] && { REFRESH_SRC="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"; break; }
done

# --- resolve the repo checkout the server reads ------------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for c in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        [[ -d "$c/.git" ]] && { REPO_ROOT="$c"; break; }
    done
fi

TARGET_BIN="${CHUMP_FLEET_SERVER_BIN:-$HOME/.local/bin/chump-fleet-server}"
PORT="${CHUMP_FLEET_SERVER_PORT:-7070}"
BIND="${CHUMP_FLEET_SERVER_BIND:-127.0.0.1}"
PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"

# --- uninstall ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[install-fleet-server-node] stopping + disabling units …"
    systemctl --user disable --now "$FLEET_UNIT" 2>/dev/null || true
    systemctl --user disable --now "$REFRESH_UNIT.timer" 2>/dev/null || true
    rm -f "$UNIT_DIR/$FLEET_UNIT" "$UNIT_DIR/$REFRESH_UNIT.service" "$UNIT_DIR/$REFRESH_UNIT.timer"
    systemctl --user daemon-reload
    echo "[install-fleet-server-node] uninstalled."
    exit 0
fi

if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
    echo "FATAL: no chump checkout found (set CHUMP_NODE_REPO)" >&2
    exit 1
fi
if [[ -z "$REFRESH_SRC" ]]; then
    echo "FATAL: cannot locate node-refresh-fleet-server.sh (set CHUMP_NODE_REPO)" >&2
    exit 1
fi
chmod +x "$REFRESH_SRC" 2>/dev/null || true

echo "[install-fleet-server-node] repo:      $REPO_ROOT"
echo "[install-fleet-server-node] binary:    $TARGET_BIN"
echo "[install-fleet-server-node] refresh:   $REFRESH_SRC"
echo "[install-fleet-server-node] bind:      $BIND:$PORT"
echo "[install-fleet-server-node] providers: $PROVIDERS_ENV"

mkdir -p "$UNIT_DIR"

# --- long-running fleet-server service ---------------------------------------
# Type=simple + Restart=always: the audit organ is a persistent HTTP server, not
# a oneshot. Sources providers.env so GH_TOKEN (dashboard-summary gh fallback)
# and CHUMP_BATPHONE_TOKEN (authed /api/gap, /api/gaps, /api/mission) are set.
{
    echo "[Unit]"
    echo "Description=Chump fleet-server — audit/dashboard API + bat-phone intake (RESILIENT-1046)"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=simple"
    echo "WorkingDirectory=$REPO_ROOT"
    echo "Environment=CHUMP_REPO_ROOT=$REPO_ROOT"
    echo "Environment=CHUMP_FLEET_SERVER_PORT=$PORT"
    echo "Environment=CHUMP_FLEET_SERVER_BIND=$BIND"
    echo "Environment=RUST_LOG=info"
    # set -a so bare (non-export) lines in providers.env are exported too.
    echo "ExecStart=/bin/bash -c 'set -a; source \"$PROVIDERS_ENV\" 2>/dev/null; set +a; exec \"$TARGET_BIN\"'"
    echo "Restart=always"
    echo "RestartSec=10"
    echo "Nice=5"
    echo ""
    echo "[Install]"
    echo "WantedBy=default.target"
} > "$UNIT_DIR/$FLEET_UNIT"

# --- refresh oneshot service -------------------------------------------------
{
    echo "[Unit]"
    echo "Description=Chump fleet-server binary refresh (pull prebuilt, install, restart) — RESILIENT-1046"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    # Pull path is seconds; bootstrap copy is instant; never a cargo build. A
    # generous ceiling still bounds a wedged gh/network call.
    echo "TimeoutStartSec=600"
    echo "Environment=CHUMP_NODE_REPO=$REPO_ROOT"
    echo "Environment=CHUMP_FLEET_SERVER_BIN=$TARGET_BIN"
    echo "Environment=CHUMP_FLEET_SERVER_UNIT=$FLEET_UNIT"
    [[ -n "${GH_TOKEN:-}" ]] && echo "Environment=GH_TOKEN=${GH_TOKEN}"
    echo "ExecStart=/usr/bin/env bash $REFRESH_SRC"
    echo "Nice=10"
} > "$UNIT_DIR/$REFRESH_UNIT.service"

# --- refresh timer -----------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=Chump fleet-server refresh timer (every ${CADENCE_MIN}m) — RESILIENT-1046"
    echo ""
    echo "[Timer]"
    echo "OnBootSec=5min"
    echo "OnUnitActiveSec=${CADENCE_MIN}min"
    echo "Persistent=true"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
} > "$UNIT_DIR/$REFRESH_UNIT.timer"

echo "wrote:"
echo "  $UNIT_DIR/$FLEET_UNIT"
echo "  $UNIT_DIR/$REFRESH_UNIT.service"
echo "  $UNIT_DIR/$REFRESH_UNIT.timer"

# --- linger (headless nodes need --user units to run without a login) --------
if command -v loginctl >/dev/null 2>&1; then
    if loginctl enable-linger "$USER" 2>/dev/null; then
        echo "linger enabled for $USER"
    else
        echo "WARN: could not enable linger — run once: sudo loginctl enable-linger $USER" >&2
    fi
fi

systemctl --user daemon-reload
# Enable the service now so a reboot brings it back; do NOT --now yet (the binary
# may not be installed). The refresh below installs the binary + starts it.
systemctl --user enable "$FLEET_UNIT" >/dev/null 2>&1 || true

# --- first refresh: install the binary (pull or bootstrap), start the server -
echo "[install-fleet-server-node] running first refresh (pull prebuilt or bootstrap) …"
CHUMP_NODE_REPO="$REPO_ROOT" CHUMP_FLEET_SERVER_BIN="$TARGET_BIN" CHUMP_FLEET_SERVER_UNIT="$FLEET_UNIT" \
    bash "$REFRESH_SRC" || echo "WARN: first refresh returned non-zero (see its log)"

# The refresh restarts the service only when it installs a NEW binary. Ensure
# the server is actually up regardless (e.g. binary was already current).
if [[ -x "$TARGET_BIN" ]]; then
    systemctl --user restart "$FLEET_UNIT" 2>/dev/null || systemctl --user start "$FLEET_UNIT" 2>/dev/null || true
else
    echo "WARN: $TARGET_BIN not present after refresh — service will not start until a binary is available" >&2
fi

systemctl --user enable --now "$REFRESH_UNIT.timer"

echo ""
echo "=== status ==="
systemctl --user is-active "$FLEET_UNIT" 2>/dev/null || true
systemctl --user list-timers "$REFRESH_UNIT.timer" --no-pager 2>/dev/null || true
echo ""
echo "Verify:  curl -s http://$BIND:$PORT/healthz && echo"
echo "Audit:   curl -s http://$BIND:$PORT/api/dashboard-summary | head"
echo "Logs:    journalctl --user -u $FLEET_UNIT -n 50 --no-pager"
echo "Refresh: systemctl --user start $REFRESH_UNIT.service"
