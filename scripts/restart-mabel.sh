#!/usr/bin/env bash
#
# restart-mabel.sh — Restart the Mabel Discord bot on the Pixel.
#
# Canonical Mac→Pixel supervision entry-point (FLEET-001). Delegates to
# restart-mabel-bot-on-pixel.sh which handles ADB/SSH path selection, retries,
# and post-restart health verification.
#
# Usage:
#   scripts/restart-mabel.sh
#
# Env (set in .env or shell):
#   PIXEL_SSH_HOST           SSH alias/IP for the Pixel (default: termux)
#   PIXEL_SSH_PORT           SSH port on Pixel (default: 8022)
#   PIXEL_USE_ADB=1          Force ADB path even when network is available
#   PIXEL_SSH_FORCE_NETWORK=1  Force Tailscale/WiFi path instead of ADB
#   RESTART_MABEL_MAX_ATTEMPTS  Retry limit (default: 3)
#
# See restart-mabel-bot-on-pixel.sh for the full env reference.
#
# Exit codes:
#   0  Mabel bot restarted and verified running
#   1  SSH unreachable or restart verification failed after retries

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/restart-mabel-bot-on-pixel.sh" "$@"
