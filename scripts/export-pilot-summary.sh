#!/usr/bin/env bash
# Fetch GET /api/pilot-summary (N4 pilot JSON). Requires web up; pass bearer if CHUMP_WEB_TOKEN is set.
set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi
PORT="${CHUMP_WEB_PORT:-3000}"
BASE="http://127.0.0.1:${PORT}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
hdr=()
if [[ -n "${TOKEN// }" ]]; then
  hdr=(-H "Authorization: Bearer ${TOKEN}")
fi
curl -sf "${hdr[@]}" "${BASE}/api/pilot-summary" | python3 -m json.tool
