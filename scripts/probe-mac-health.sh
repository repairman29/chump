#!/data/data/com.termux/files/usr/bin/bash
# FLEET-001: Mabel (Pixel/Termux) probes Mac Chump's /api/dashboard.
#
# Runs from Pixel. Checks that Mac's Chump web server is up and the fleet
# status is healthy (not "red"). Prints a one-line status report and
# exits 0 (healthy), 1 (degraded/unreachable), or 2 (red fleet status).
#
# Usage: bash scripts/probe-mac-health.sh [--quiet]
#   --quiet  Suppress output except on failure.
#
# Env vars (load from .env automatically):
#   MAC_WEB_HOST    default: mac (Tailscale/SSH config name)
#   MAC_WEB_PORT    default: 3000
#   CHUMP_WEB_TOKEN optional bearer token (CHUMP_WEB_TOKEN on Mac)
#   FLEET_HEALTH_TIMEOUT  default: 8

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

MAC_HOST="${MAC_WEB_HOST:-mac}"
MAC_PORT="${MAC_WEB_PORT:-3000}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
TIMEOUT="${FLEET_HEALTH_TIMEOUT:-8}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

URL="http://${MAC_HOST}:${MAC_PORT}/api/dashboard"
CURL_ARGS=(--silent --max-time "${TIMEOUT}")
if [[ -n "${TOKEN}" ]]; then
  CURL_ARGS+=(-H "Authorization: Bearer ${TOKEN}")
fi

log() { [[ "${QUIET}" == "0" ]] && echo "$*" || true; }

log "probe-mac-health: probing ${URL}..."
if ! BODY=$(curl "${CURL_ARGS[@]}" "${URL}" 2>&1); then
  echo "ERROR: cannot reach Mac Chump at ${URL}" >&2
  exit 1
fi

# Parse fleet_status from JSON (pure bash — no jq dependency on Termux by default)
FLEET_STATUS=$(echo "${BODY}" | grep -o '"fleet_status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
SHIP_RUNNING=$(echo "${BODY}" | grep -o '"ship_running":[^,}]*' | head -1 | grep -c "true" || echo "0")

log "probe-mac-health: fleet_status=${FLEET_STATUS} ship_running=${SHIP_RUNNING}"

case "${FLEET_STATUS}" in
  green)
    log "probe-mac-health: Mac is HEALTHY (green)"
    exit 0
    ;;
  yellow)
    echo "WARN: Mac fleet status is YELLOW (degraded)" >&2
    exit 1
    ;;
  red | "")
    echo "ERROR: Mac fleet status is RED (or unreadable)" >&2
    exit 2
    ;;
  *)
    log "probe-mac-health: unknown status '${FLEET_STATUS}' — treating as degraded"
    exit 1
    ;;
esac
