#!/usr/bin/env bash
# test-verified-recompute.sh — RESILIENT-1562: stubbed-gh decision test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$T_LOG"
case "$1 $2" in
  "run list") echo "$RUNS" ;;
  "api repos/"*) echo "$JOBS" ;;
  "run rerun") echo RERUN ;;
esac
STUB
chmod +x "$T/gh"
export T_LOG="$T/log" PATH="$T:$PATH"
fails=0
run() { : > "$T_LOG"; bash "$ROOT/scripts/ci/verified-recompute.sh" --sha abc --repo o/r; }

export RUNS='[{"databaseId":7,"status":"completed"}]' JOBS='{"id":99,"name":"verified","conclusion":"failure"}'
run >/dev/null; grep -q 'run rerun.*7 --job 99' "$T_LOG" && echo PASS: reruns failed verified || { echo FAIL: rerun; fails=1; }
export JOBS='{"id":99,"name":"verified","conclusion":"success"}'
run >/dev/null; grep -q 'run rerun' "$T_LOG" && { echo FAIL: reran green; fails=1; } || echo PASS: skips green
export RUNS='[{"databaseId":7,"status":"in_progress"}]' JOBS='{"id":99,"name":"verified","conclusion":"failure"}'
run >/dev/null; grep -q 'run rerun' "$T_LOG" && { echo FAIL: reran in-progress; fails=1; } || echo PASS: skips in-progress run
export RUNS='[]'
run >/dev/null; grep -q 'run rerun' "$T_LOG" && { echo FAIL: reran none; fails=1; } || echo PASS: no run
exit $fails
