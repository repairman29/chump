#!/usr/bin/env bash
# Remote (or local) control of Chump ship autopilot via HTTP.
# Usage: CHUMP_AUTOPILOT_URL=http://100.x.y.z:3000 CHUMP_WEB_TOKEN=secret ./scripts/autopilot-remote.sh status|start|stop
set -euo pipefail
URL="${CHUMP_AUTOPILOT_URL:-http://127.0.0.1:3000}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
cmd="${1:-}"

auth_header=()
if [[ -n "$TOKEN" ]]; then
  auth_header=(-H "Authorization: Bearer ${TOKEN}")
fi

case "$cmd" in
  status)
    curl -sS "${auth_header[@]}" "${URL}/api/autopilot/status" | jq .
    ;;
  start)
    curl -sS -X POST "${auth_header[@]}" "${URL}/api/autopilot/start" | jq .
    ;;
  stop)
    curl -sS -X POST "${auth_header[@]}" "${URL}/api/autopilot/stop" | jq .
    ;;
  *)
    echo "Usage: CHUMP_AUTOPILOT_URL=... CHUMP_WEB_TOKEN=... $0 status|start|stop" >&2
    exit 2
    ;;
esac
