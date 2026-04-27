#!/usr/bin/env bash
# Poll until an OpenAI-compatible **/v1/models** endpoint returns HTTP 200.
# Does **not** start, stop, or restart the model server (no Ollama stop, no second vllm-mlx).
# Use this after `./scripts/setup/restart-vllm-if-down.sh` or `./serve-vllm-mlx.sh` so health checks and
# dogfood probes do not overlap with cron/oven-tender spawning duplicate downloads.
#
# Usage:
#   ./scripts/setup/wait-for-vllm.sh
#   CHUMP_VLLM_MODELS_URL=http://127.0.0.1:8001/v1/models ./scripts/setup/wait-for-vllm.sh
#   CHUMP_WAIT_VLLM_TIMEOUT_SECS=3600 ./scripts/setup/wait-for-vllm.sh   # first HF pull can exceed 20 min
#
# Environment:
#   CHUMP_VLLM_MODELS_URL        Full URL (default: from OPENAI_API_BASE + /models, else 127.0.0.1:8000/v1/models)
#   CHUMP_WAIT_VLLM_TIMEOUT_SECS Max wait (default: 1200)
#   CHUMP_WAIT_VLLM_INTERVAL_SECS Sleep between probes (default: 10)
#   CHUMP_WAIT_VLLM_CURL_SECS      Per-request curl --max-time (default: 8)
#   CHUMP_WAIT_VLLM_QUIET=1        Less stderr chatter

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

TIMEOUT="${CHUMP_WAIT_VLLM_TIMEOUT_SECS:-1200}"
INTERVAL="${CHUMP_WAIT_VLLM_INTERVAL_SECS:-10}"
CURL_MAX="${CHUMP_WAIT_VLLM_CURL_SECS:-8}"
QUIET="${CHUMP_WAIT_VLLM_QUIET:-0}"

URL="${CHUMP_VLLM_MODELS_URL:-}"
if [[ -z "$URL" ]]; then
  base="${OPENAI_API_BASE:-http://127.0.0.1:8000/v1}"
  base="${base%/}"
  URL="${base}/models"
fi

log() {
  if [[ "$QUIET" != "1" ]]; then
    printf '%s\n' "$*" >&2
  fi
}

log "wait-for-vllm: probing ${URL} (timeout ${TIMEOUT}s, interval ${INTERVAL}s)"

start_ts=$(date +%s)
attempt=0
while true; do
  attempt=$((attempt + 1))
  now_ts=$(date +%s)
  elapsed=$((now_ts - start_ts))
  if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
    log "wait-for-vllm: timeout after ${elapsed}s (${attempt} attempts)"
    exit 1
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX" "$URL" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    log "wait-for-vllm: ready after ${elapsed}s (HTTP 200, attempt ${attempt})"
    if command -v python3 &>/dev/null; then
      id="$(curl -s --max-time "$CURL_MAX" "$URL" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(d["data"][0]["id"])
except Exception:
  print("(could not parse model id)")' 2>/dev/null || true)"
      log "wait-for-vllm: first model id: ${id}"
    fi
    exit 0
  fi
  log "wait-for-vllm: attempt ${attempt} HTTP ${code} (+${elapsed}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
done
