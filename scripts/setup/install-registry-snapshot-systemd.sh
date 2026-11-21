#!/usr/bin/env bash
# install-registry-snapshot-systemd.sh — RESILIENT-1902: daily 06:00Z registry snapshot timer (hub).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cat >"$UNIT_DIR/chump-registry-snapshot.service" <<UNIT
[Unit]
Description=chump registry snapshot (RESILIENT-1902)
[Service]
Type=oneshot
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/env bash $REPO_ROOT/scripts/ops/registry-snapshot.sh snapshot
UNIT
cat >"$UNIT_DIR/chump-registry-snapshot.timer" <<UNIT
[Unit]
Description=daily chump registry snapshot (06:00Z)
[Timer]
OnCalendar=*-*-* 06:00:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now chump-registry-snapshot.timer
