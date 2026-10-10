#!/usr/bin/env bash
# RESILIENT-1560: gate-fail lane classifier test.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
L="$R/scripts/coord/lib/pr-gate-fail-lane.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk() { # number title conclusion
  printf '{"number":%s,"title":"%s","headRefOid":"sha%s","statusCheckRollup":[{"name":"verified","status":"COMPLETED","conclusion":"%s"}]}' "$1" "$2" "$1" "$3"
}
PRS="[$(mk 1 'INFRA-1: det' FAILURE),$(mk 2 'INFRA-2: flk' TIMED_OUT),$(mk 3 'INFRA-3: ok' SUCCESS)]"
export CHUMP_GATE_FAIL_NOW=1000000
# first sight: nothing (age 0)
out=$(printf '%s' "$PRS" | python3 "$L" "$T/s.json"); [ -z "$out" ] || { echo "FAIL: acted at age 0"; exit 1; }
export CHUMP_GATE_FAIL_NOW=$((1000000 + 3*3600))
out=$(printf '%s' "$PRS" | python3 "$L" "$T/s.json")
echo "$out" | grep -q '"pr": 1.*"route_fix"' || { echo "FAIL: no route_fix"; exit 1; }
echo "$out" | grep -q '"pr": 2.*"rerun"' || { echo "FAIL: no rerun"; exit 1; }
echo "$out" | grep -q '"pr": 3' && { echo "FAIL: green PR acted"; exit 1; }
# debounce
out=$(printf '%s' "$PRS" | python3 "$L" "$T/s.json"); [ -z "$out" ] || { echo "FAIL: not debounced: $out"; exit 1; }
# block after M cycles + alarm when count > threshold
export CHUMP_GATE_FAIL_BLOCK_CYCLES=2 CHUMP_GATE_FAIL_ALARM_THRESHOLD=1
out=$(printf '%s' "$PRS" | python3 "$L" "$T/s.json")
echo "$out" | grep -q '"block_gap"' || { echo "FAIL: no block_gap"; exit 1; }
echo "$out" | grep -q '"alarm"' || { echo "FAIL: no alarm"; exit 1; }
echo "[test-pr-gate-fail-lane] PASS"
