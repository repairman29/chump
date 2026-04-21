#!/usr/bin/env bash
# measure-ftue.sh — FTUE stopwatch for UX-001.
#
# Times the full first-run flow: `chump init` until the PWA at
# localhost:<PORT>/v2/ responds with HTTP 200.
#
# Usage:
#   ./scripts/measure-ftue.sh [--port 3000] [--budget 90] [--no-browser]
#
# Options:
#   --port N       Port the chump web server listens on (default 3000)
#   --budget N     Fail if FTUE > N seconds (default 90 for CI, 60 for dev)
#   --no-browser   Skip the browser-open step (for CI)
#
# Exit codes:
#   0  FTUE <= budget
#   1  FTUE > budget
#   2  Usage error

set -euo pipefail

PORT="${PORT:-3000}"
BUDGET_S="${FTUE_BUDGET:-90}"
NO_BROWSER="${NO_BROWSER:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)     PORT="$2"; shift 2 ;;
        --budget)   BUDGET_S="$2"; shift 2 ;;
        --no-browser) NO_BROWSER=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

PWA_URL="http://localhost:${PORT}/v2/"
START_TS=$(date +%s%N)  # nanoseconds

echo "[ftue] Starting FTUE measurement (budget=${BUDGET_S}s)"
echo "[ftue] PWA target: ${PWA_URL}"

# Run chump init (with --no-browser for clean measurement in CI)
if [[ "$NO_BROWSER" == "1" ]]; then
    NO_BROWSER=1 chump init 2>&1 || true
else
    chump init 2>&1 || true
fi

# Poll until PWA responds or budget exceeded
echo "[ftue] Waiting for PWA to respond..."
READY=0
while true; do
    NOW_TS=$(date +%s%N)
    ELAPSED_MS=$(( (NOW_TS - START_TS) / 1000000 ))
    ELAPSED_S=$(( ELAPSED_MS / 1000 ))

    if curl -sf --max-time 2 "${PWA_URL}" -o /dev/null 2>/dev/null; then
        READY=1
        break
    fi

    if (( ELAPSED_S >= BUDGET_S + 5 )); then
        # Hard stop 5s after budget — don't hang forever
        echo "[ftue] Hard timeout at ${ELAPSED_S}s — giving up"
        break
    fi
    sleep 1
done

END_TS=$(date +%s%N)
TOTAL_MS=$(( (END_TS - START_TS) / 1000000 ))
TOTAL_S=$(( TOTAL_MS / 1000 ))
TOTAL_S_FRAC=$(printf "%.1f" "$(echo "$TOTAL_MS / 1000" | bc -l 2>/dev/null || echo "$TOTAL_S")")

if [[ "$READY" == "1" ]]; then
    echo "[ftue] READY in ${TOTAL_S_FRAC}s"
    if (( TOTAL_S <= BUDGET_S )); then
        echo "[ftue] PASS: ${TOTAL_S_FRAC}s <= ${BUDGET_S}s budget"
        exit 0
    else
        echo "[ftue] FAIL: ${TOTAL_S_FRAC}s > ${BUDGET_S}s budget"
        exit 1
    fi
else
    echo "[ftue] FAIL: PWA never responded within ${BUDGET_S}s"
    exit 1
fi
