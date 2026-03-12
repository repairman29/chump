#!/usr/bin/env bash
# One-command: run full 500-query battle QA and print report.
# Usage: ./scripts/run-battle-qa-full.sh
#        BATTLE_QA_TIMEOUT=120 ./scripts/run-battle-qa-full.sh
# Writes: logs/battle-qa.log, logs/battle-qa-failures.txt, logs/battle-qa-report.txt

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
REPORT="$ROOT/logs/battle-qa-report.txt"
mkdir -p "$ROOT/logs"

echo "Running full 500-query battle QA (this can take a while)..."
if ./scripts/battle-qa.sh; then
  echo "PASS" > "$REPORT"
  echo "=== Battle QA: ALL 500 PASSED ==="
  exit 0
fi

# Run finished with failures; summarize
FAILURES_TXT="$ROOT/logs/battle-qa-failures.txt"
FAIL_COUNT=$(grep -c '^FAIL ' "$FAILURES_TXT" 2>/dev/null || echo 0)
echo "FAIL ($FAIL_COUNT failures)" > "$REPORT"
echo "" >> "$REPORT"
echo "Failures: $FAIL_COUNT. See $FAILURES_TXT" >> "$REPORT"
echo "=== Battle QA: $FAIL_COUNT failure(s) ==="
echo "Details: $FAILURES_TXT"
echo "Summary: $REPORT"
tail -20 "$ROOT/logs/battle-qa.log" 2>/dev/null || true
exit 1
