#!/usr/bin/env bash
# INFRA-511: Weekly CI health measurement.
# Runs `chump ci-summary --since 7d`, emits kind=ci_health ALERT to
# ambient.jsonl if failure rate exceeds CHUMP_CI_ALERT_THRESHOLD (default 10%).
#
# Usage: ci-health-weekly.sh [--json] [--threshold N]
#
# Intended to run from cron or a CI schedule (e.g. weekly `.github/workflows/`
# job). Exit 1 if failure rate is over threshold, 0 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

THRESHOLD="${CHUMP_CI_ALERT_THRESHOLD:-10}"
JSON_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --json)        JSON_FLAG="--json" ;;
    --threshold=*) THRESHOLD="${arg#*=}" ;;
    --threshold)   shift; THRESHOLD="$1" ;;
  esac
done

CHUMP="$REPO_ROOT/target/release/chump"
if [[ ! -x "$CHUMP" ]]; then
  CHUMP="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
  CHUMP="chump"  # fall back to PATH
fi

echo "[ci-health-weekly] running ci-summary --since 7d --emit-alert --threshold $THRESHOLD"
"$CHUMP" ci-summary --since 7d --emit-alert --threshold "$THRESHOLD" $JSON_FLAG
RATE=$("$CHUMP" ci-summary --since 7d --json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    t=d['total_runs_checked']; f=d['failed_runs']; \
    print(f*100//t if t else 0)" 2>/dev/null || echo "0")

if (( RATE > THRESHOLD )); then
  echo "[ci-health-weekly] ALERT: failure rate ${RATE}% > threshold ${THRESHOLD}%" >&2
  exit 1
fi
echo "[ci-health-weekly] OK: failure rate ${RATE}% <= threshold ${THRESHOLD}%"
