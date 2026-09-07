#!/usr/bin/env bash
# scripts/ops/install-pixel-builder-systemd.sh — RESILIENT-1044
#
# Install the owned-iron build-offload timer on an OPS host (e.g. the brain,
# cuphead). The timer runs scripts/ops/build-on-pixel.sh every 30 min, which
# ssh-drives the Pixel to build + publish the green-main `chump` binary to the
# fleet-binaries GitHub Release. Nodes then pull that owned-built asset via
# node-refresh-chump.sh (_try_release_pull) instead of ever cold-building.
#
# SAFE ON THE BRAIN: the timer does NO local cargo — it only ssh's to the Pixel.
# The whole point is that the phone (8 real cores) builds, not the 2-core node.
#
# PRECONDITION: this host can `ssh <PIXEL_SSH>` non-interactively (key-based) and
# the Pixel has gh authenticated (for the release upload). Verify with:
#   ssh "${PIXEL_SSH:-termux}" 'gh auth status'
#
# Idempotent: re-running rewrites the units and re-enables the timer.
#
# Env:
#   PIXEL_SSH        ssh host alias for the Pixel (default: termux) — baked into the unit
#   RELEASE_TAG      GH release tag               (default: fleet-binaries) — baked in
#   CHUMP_NODE_REPO  mirror checkout to run from  (default: ~/chump-host)
#   CADENCE_MIN      timer cadence in minutes     (default: 30)

set -euo pipefail

PIXEL_SSH="${PIXEL_SSH:-termux}"
RELEASE_TAG="${RELEASE_TAG:-fleet-binaries}"
CADENCE_MIN="${CADENCE_MIN:-30}"
UNIT_DIR="$HOME/.config/systemd/user"

# --- resolve the mirror checkout this ops host runs from ----------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for c in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump" \
             "$(cd "$(dirname "$0")/../.." && pwd)"; do
        if [[ -d "$c/.git" ]]; then REPO_ROOT="$c"; break; fi
    done
fi
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "FATAL: no chump checkout found (set CHUMP_NODE_REPO)" >&2; exit 1; }
SCRIPT_SRC="$REPO_ROOT/scripts/ops/build-on-pixel.sh"
[[ -f "$SCRIPT_SRC" ]] || { echo "FATAL: $SCRIPT_SRC missing" >&2; exit 1; }
chmod +x "$SCRIPT_SRC" "$REPO_ROOT/scripts/ops/pixel-build-and-publish.sh" 2>/dev/null || true
echo "offload script: $SCRIPT_SRC"
echo "pixel host:     $PIXEL_SSH"
echo "release tag:    $RELEASE_TAG"

# --- reachability warning (not fatal — the timer self-recovers when it's back) --
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$PIXEL_SSH" 'gh auth status' >/dev/null 2>&1; then
    echo "precheck: Pixel reachable + gh authed ✓"
else
    echo "WARN: cannot ssh '$PIXEL_SSH' non-interactively OR gh not authed there." >&2
    echo "      Fix key-based ssh + 'gh auth login' on the Pixel; the timer will start working once it's reachable." >&2
fi

mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/chump-pixel-builder.service" <<EOF
[Unit]
Description=chump owned-iron build-offload (build release binary on the Pixel, publish to $RELEASE_TAG) — RESILIENT-1044
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=3600
Environment=CHUMP_NODE_REPO=$REPO_ROOT
Environment=PIXEL_SSH=$PIXEL_SSH
Environment=RELEASE_TAG=$RELEASE_TAG
ExecStart=/usr/bin/env bash $SCRIPT_SRC
Nice=10

[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/chump-pixel-builder.timer" <<EOF
[Unit]
Description=periodic owned-iron build-offload — build the green-main chump binary on the Pixel — RESILIENT-1044

[Timer]
OnBootSec=3min
OnUnitActiveSec=${CADENCE_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# --- linger so the --user timer runs without an active login -----------------
loginctl enable-linger "$USER" 2>/dev/null || \
    echo "NOTE: could not enable-linger (run: sudo loginctl enable-linger $USER) — timer needs it on headless hosts"

systemctl --user daemon-reload
systemctl --user enable --now chump-pixel-builder.timer

echo "installed + enabled chump-pixel-builder.timer (every ${CADENCE_MIN} min)"
systemctl --user list-timers chump-pixel-builder.timer --no-pager 2>/dev/null || true
echo "one-shot now:   systemctl --user start chump-pixel-builder.service"
echo "logs:           journalctl --user -u chump-pixel-builder.service -n 50 --no-pager"
