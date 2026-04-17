#!/usr/bin/env bash
# FLEET-001: Mac can SSH-restart Mabel (Pixel/Termux).
#
# Stops the running chump --discord process on Pixel (if any), then calls
# ensure-mabel-bot-up.sh so Mabel re-launches in a clean state.
#
# Usage: bash scripts/restart-mabel.sh [--force] [--dry-run]
#   --force    Kill the bot process even if the llama-server is not ready.
#   --dry-run  Print what would be run without executing.
#
# Env vars (load from .env automatically):
#   PIXEL_SSH_HOST   default: termux
#   PIXEL_SSH_PORT   default: 8022
#   FLEET_HEALTH_TIMEOUT  default: 10
#
# Exit codes:
#   0  Mabel confirmed running after restart
#   1  Could not reach Pixel
#   2  Mabel did not come up after restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

PIXEL_HOST="${PIXEL_SSH_HOST:-termux}"
PIXEL_PORT="${PIXEL_SSH_PORT:-8022}"
TIMEOUT="${FLEET_HEALTH_TIMEOUT:-10}"
FORCE=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
  esac
done

SSH_OPTS=(-o ConnectTimeout="${TIMEOUT}" -o BatchMode=yes -o StrictHostKeyChecking=no -p "${PIXEL_PORT}")

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] ssh ${PIXEL_HOST}: $*"
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "${PIXEL_HOST}" "$@"
}

echo "restart-mabel: connecting to ${PIXEL_HOST}:${PIXEL_PORT}..."

# Verify connectivity
if ! run "echo connected" >/dev/null 2>&1; then
  echo "ERROR: cannot reach Pixel at ${PIXEL_HOST}:${PIXEL_PORT}" >&2
  exit 1
fi

echo "restart-mabel: stopping existing chump --discord process..."
run "pkill -f 'chump.*--discord' 2>/dev/null || true; pkill -f 'start-companion' 2>/dev/null || true"
sleep 2

if [[ "${FORCE}" == "1" ]]; then
  echo "restart-mabel: --force: launching bot directly..."
  run "cd ~/chump && bash scripts/ensure-mabel-bot-up.sh"
else
  echo "restart-mabel: calling ensure-mabel-bot-up.sh on Pixel..."
  if ! run "cd ~/chump && bash scripts/ensure-mabel-bot-up.sh"; then
    echo "ERROR: ensure-mabel-bot-up.sh failed (llama-server may not be ready)" >&2
    exit 2
  fi
fi

# Wait up to 15s for the bot to appear
echo "restart-mabel: waiting for chump --discord..."
for i in $(seq 1 15); do
  if run "pgrep -f 'chump.*--discord'" >/dev/null 2>&1; then
    echo "restart-mabel: Mabel is running (verified in ${i}s)."
    exit 0
  fi
  sleep 1
done

echo "ERROR: Mabel process not detected after 15s" >&2
exit 2
