#!/usr/bin/env bash
# Optional smoke after EXTERNAL_GOLDEN_PATH: PWA API task create + list (no Discord).
# From repo root with web already running (./run-web.sh). See docs/WEDGE_H1_GOLDEN_EXTENSION.md
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

echo "[wedge-h1] GET ${BASE}/api/health"
curl -sf "${BASE}/api/health" | head -c 200
echo
echo "[wedge-h1] POST ${BASE}/api/tasks (pilot task)"
tid=$(curl -sf "${hdr[@]}" -X POST "${BASE}/api/tasks" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"wedge-h1-smoke $(date +%Y%m%d-%H%M%S)\"}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
if [[ -z "${tid}" ]]; then
  echo "[wedge-h1] ERROR: no task id returned (401? set CHUMP_WEB_TOKEN in curl via .env)" >&2
  exit 1
fi
echo "[wedge-h1] created task id=${tid}"
echo "[wedge-h1] GET ${BASE}/api/tasks (first lines)"
curl -sf "${hdr[@]}" "${BASE}/api/tasks" | head -c 400
echo
echo "[wedge-h1] OK — see docs/WEDGE_H1_GOLDEN_EXTENSION.md for autonomy_once step"
