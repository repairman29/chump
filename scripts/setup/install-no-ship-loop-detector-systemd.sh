#!/usr/bin/env bash
# RESILIENT-1573: Linux counterpart — systemd --user timer for no-ship-loop-detector.
# Requires `loginctl enable-linger $USER`. Uninstall:
#   systemctl --user disable --now chump-no-ship-loop-detector.timer
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INTERVAL="${CHUMP_NO_SHIP_LOOP_INTERVAL_S:-900}"
DET="$REPO_ROOT/scripts/coord/no-ship-loop-detector.sh"
UNIT_DIR="$HOME/.config/systemd/user"
[[ -f "$DET" ]] || { echo "ERROR: detector not found at $DET" >&2; exit 1; }
mkdir -p "$UNIT_DIR"
_PATH="$HOME/.local/bin:$HOME/.cargo/bin:$REPO_ROOT/target/release:/usr/local/bin:/usr/bin:/bin"
cat >"$UNIT_DIR/chump-no-ship-loop-detector.service" <<EOF2
[Unit]
Description=chump no-ship-loop + service crash-loop detector (RESILIENT-1573)

[Service]
Type=oneshot
Environment=HOME=%h
Environment=PATH=$_PATH
Environment=REPO_ROOT=$REPO_ROOT
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/env bash $DET tick
EOF2
cat >"$UNIT_DIR/chump-no-ship-loop-detector.timer" <<EOF2
[Unit]
Description=chump no-ship-loop detector timer (every ${INTERVAL}s) — RESILIENT-1573

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF2
systemctl --user daemon-reload
systemctl --user enable --now chump-no-ship-loop-detector.timer
echo "Installed chump-no-ship-loop-detector.timer (every ${INTERVAL}s)"
