#!/usr/bin/env bash
#
# probe-mac-health.sh — Probe Mac's Chump web API from the Pixel.
#
# Pixel→Mac mutual supervision (FLEET-001). Queries /api/dashboard on the Mac
# and exits 0 on HTTP 200. Designed to run standalone from the Pixel (Termux)
# or from mabel-farmer.sh as an explicit health gate.
#
# Usage:
#   ./scripts/probe-mac-health.sh           # probe and print result
#   ./scripts/probe-mac-health.sh --quiet   # suppress output on success
#   ./scripts/probe-mac-health.sh --json    # print dashboard JSON on success
#
# Env (set in ~/chump/.env on the Pixel):
#   MAC_TAILSCALE_IP    Tailscale IP of the Mac (required)
#   MAC_WEB_PORT        Web server port on Mac (required, e.g. 3000)
#   CHUMP_WEB_TOKEN     Bearer token for /api/dashboard auth (required unless unprotected)
#   PROBE_MAC_TIMEOUT   curl timeout in seconds (default: 10)
#
# Exit codes:
#   0  /api/dashboard returned HTTP 200
#   1  HTTP non-200, network failure, or required env var missing

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

QUIET=0
SHOW_JSON=0
for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --json)  SHOW_JSON=1 ;;
    esac
done

MAC_IP="${MAC_TAILSCALE_IP:-}"
MAC_WEB_PORT="${MAC_WEB_PORT:-}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
TIMEOUT="${PROBE_MAC_TIMEOUT:-10}"

if [[ -z "$MAC_IP" ]]; then
    echo "probe-mac-health: ERROR: MAC_TAILSCALE_IP not set." >&2
    exit 1
fi
if [[ -z "$MAC_WEB_PORT" ]]; then
    echo "probe-mac-health: ERROR: MAC_WEB_PORT not set." >&2
    exit 1
fi

URL="http://${MAC_IP}:${MAC_WEB_PORT}/api/dashboard"
AUTH_HEADER=()
[[ -n "$TOKEN" ]] && AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")

if [[ $SHOW_JSON -eq 1 ]]; then
    # Fetch body + status code together
    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -s -o "$TMPFILE" -w "%{http_code}" \
        --max-time "$TIMEOUT" "${AUTH_HEADER[@]}" "$URL" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        [[ $QUIET -eq 0 ]] && echo "probe-mac-health: OK — $URL"
        cat "$TMPFILE"
        rm -f "$TMPFILE"
        exit 0
    else
        echo "probe-mac-health: FAIL — $URL returned HTTP $HTTP_CODE" >&2
        rm -f "$TMPFILE"
        exit 1
    fi
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$TIMEOUT" "${AUTH_HEADER[@]}" "$URL" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    [[ $QUIET -eq 0 ]] && echo "probe-mac-health: OK — Mac /api/dashboard responded 200 (${URL})"
    exit 0
else
    echo "probe-mac-health: FAIL — Mac /api/dashboard returned HTTP ${HTTP_CODE} (${URL})" >&2
    [[ -z "$TOKEN" ]] && echo "probe-mac-health: hint: set CHUMP_WEB_TOKEN if Mac requires auth." >&2
    exit 1
fi
