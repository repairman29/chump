#!/usr/bin/env bash
# One-command: run full 500-query battle QA and print report.
# Usage: ./scripts/run-battle-qa-full.sh
#        BATTLE_QA_TIMEOUT=120 ./scripts/run-battle-qa-full.sh
# Writes: logs/battle-qa.log, logs/battle-qa-failures.txt, logs/battle-qa-report.txt

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
REPORT="$ROOT/logs/battle-qa-report.txt"
FAILURES_TXT="$ROOT/logs/battle-qa-failures.txt"
mkdir -p "$ROOT/logs"

write_report() {
  local status="$1"
  local count="${2:-0}"
  echo "$status" > "$REPORT"
  echo "Report written at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REPORT"
  if [[ "$status" == "FAIL" ]]; then
    echo "" >> "$REPORT"
    echo "Failures: $count. See $FAILURES_TXT" >> "$REPORT"
  fi
}
trap 'write_report "INTERRUPTED" "$(grep -c "^FAIL " "$FAILURES_TXT" 2>/dev/null || echo 0)"; exit 130' INT TERM

# Preflight: model server must be reachable
if ! ./scripts/check-heartbeat-preflight.sh &>/dev/null; then
  echo "Preflight FAIL: model server not reachable. Start Ollama or vLLM-MLX, then re-run." >&2
  write_report "PREFLIGHT_FAIL" 0
  exit 1
fi

echo "Running full 500-query battle QA (this can take a while)..."
if ./scripts/battle-qa.sh; then
  write_report "PASS"
  echo "=== Battle QA: ALL 500 PASSED ==="
  exit 0
fi

# Run finished with failures; summarize
FAIL_COUNT=$(grep -c '^FAIL ' "$FAILURES_TXT" 2>/dev/null || echo 0)
write_report "FAIL" "$FAIL_COUNT"
echo "=== Battle QA: $FAIL_COUNT failure(s) ==="
echo "Details: $FAILURES_TXT"
echo "Summary: $REPORT"
tail -20 "$ROOT/logs/battle-qa.log" 2>/dev/null || true
exit 1
