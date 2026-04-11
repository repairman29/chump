#!/usr/bin/env bash
# W3.4 — Cold-start / golden path timing: record phase durations for regression tracking.
# Does not start Ollama or the web server unless you opt in (see env below).
#
# Usage (repo root):
#   ./scripts/golden-path-timing.sh
#   GOLDEN_TIMING_HIT_HEALTH=1 ./scripts/golden-path-timing.sh   # requires web already on CHUMP_WEB_HOST:PORT
#   GOLDEN_TIMING_INCLUDE_TEST=1 ./scripts/golden-path-timing.sh
#
# Output: logs/golden-path-timing-YYYY-MM-DD.jsonl (override with GOLDEN_TIMING_LOG=path)
# Exit 1 if cargo build seconds exceed GOLDEN_MAX_CARGO_BUILD_SEC (default 900).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/logs"
OUT="${GOLDEN_TIMING_LOG:-$ROOT/logs/golden-path-timing-$(date +%Y-%m-%d).jsonl}"
HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
PORT="${CHUMP_WEB_PORT:-3000}"
MAX_BUILD="${GOLDEN_MAX_CARGO_BUILD_SEC:-900}"

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

append_json() {
  # $1 = step, $2 = seconds (number), optional $3 = extra json fragment e.g. ,"skipped":true
  local step="$1" sec="$2" extra="${3:-}"
  printf '{"step":"%s","seconds":%s,"ts":"%s"%s}\n' "$step" "$sec" "$(ts_utc)" "$extra" >> "$OUT"
}

echo "== golden-path-timing: log=$OUT max_cargo_build_sec=$MAX_BUILD =="

t0=$(date +%s)
cargo build -q
t1=$(date +%s)
build_sec=$((t1 - t0))
append_json cargo_build "$build_sec"
echo "cargo build: ${build_sec}s"

if [[ "${GOLDEN_TIMING_INCLUDE_TEST:-0}" == "1" ]]; then
  t0=$(date +%s)
  cargo test -q --lib --no-run 2>/dev/null || cargo test -q --no-run
  t1=$(date +%s)
  append_json cargo_test_compile_only $((t1 - t0))
  echo "cargo test --no-run: $((t1 - t0))s"
fi

if [[ "${GOLDEN_TIMING_HIT_HEALTH:-0}" == "1" ]]; then
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://${HOST}:${PORT}/api/health" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    t0=$(date +%s)
    curl -s --max-time 10 "http://${HOST}:${PORT}/api/health" >/dev/null
    t1=$(date +%s)
    append_json api_health_get $((t1 - t0))
    echo "GET /api/health: $((t1 - t0))s"
  else
    append_json api_health_get 0 ',"skipped":true,"http_status":"'"$code"'"'
    echo "GET /api/health: skipped (HTTP $code; start web or unset GOLDEN_TIMING_HIT_HEALTH)"
  fi
fi

append_json golden_path_timing_done 0 ',"meta":{"host":"'"$HOST"'","port":"'"$PORT"'"}'

if [[ "$build_sec" -gt "$MAX_BUILD" ]]; then
  echo "FAIL: cargo build (${build_sec}s) > GOLDEN_MAX_CARGO_BUILD_SEC=${MAX_BUILD}"
  append_json regression_cargo_build "$build_sec" ',"limit":'"$MAX_BUILD"',"fail":true'
  echo "Suggested task: [COS] Golden path regression — cargo build ${build_sec}s (limit ${MAX_BUILD}s). See $OUT"
  exit 1
fi
echo "OK: golden-path-timing within cargo build threshold."
