#!/usr/bin/env bash
# test-fleet-metrics-snapshot.sh — INFRA-900
#
# 8 tests verifying fleet-metrics-snapshot.sh:
#  1. script exists and is executable
#  2. kind=fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml
#  3. INFRA-900 referenced in script
#  4. emits fleet_metrics_snapshot event to ambient.jsonl
#  5. event has all required fields: ts, kind, ship_rate_24h, waste_rate_24h,
#     cycle_time_p50_h, active_gaps, p0_count
#  6. ship_rate_24h is numeric (float 0..1 when pr data present)
#  7. --dry-run suppresses ambient write
#  8. --json outputs JSON to stdout containing required fields

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/ops/fleet-metrics-snapshot.sh"

pass=0
fail=0
ok()  { echo "  PASS $1"; pass=$((pass + 1)); }
err() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "=== test-fleet-metrics-snapshot.sh ==="

# Test 1: script exists and executable
if [[ -x "$SCRIPT" ]]; then
    ok "1: fleet-metrics-snapshot.sh exists and is executable"
else
    err "1: fleet-metrics-snapshot.sh missing or not executable"
fi

# Test 2: kind=fleet_metrics_snapshot registered in EVENT_REGISTRY
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "fleet_metrics_snapshot" "$REGISTRY" 2>/dev/null; then
    ok "2: fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml"
else
    err "2: fleet_metrics_snapshot not found in EVENT_REGISTRY.yaml"
fi

# Test 3: INFRA-900 referenced in script
if grep -q "INFRA-900" "$SCRIPT" 2>/dev/null; then
    ok "3: INFRA-900 referenced in fleet-metrics-snapshot.sh"
else
    err "3: INFRA-900 not referenced in fleet-metrics-snapshot.sh"
fi

# Set up isolated temp env for remaining tests
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_AMB="$TMP/ambient.jsonl"
touch "$FAKE_AMB"

# Fake chump that returns predictable gap data
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'FAKECHUMP'
#!/usr/bin/env bash
# fake chump for test isolation
if [[ "${1:-}" == "gap" && "${2:-}" == "list" ]]; then
    echo "[open] INFRA-001 — Some P0 gap (P0/s)"
    echo "[open] INFRA-002 — Another P1 gap (P1/xs)"
    echo "[open] INFRA-003 — Third P1 gap (P1/m)"
    exit 0
fi
if [[ "${1:-}" == "waste-tally" ]]; then
    echo '{"waste_rate": 0.12}'
    exit 0
fi
exit 1
FAKECHUMP
chmod +x "$TMP/bin/chump"
export PATH="$TMP/bin:$PATH"

# Test 4: emits fleet_metrics_snapshot to ambient.jsonl
REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$FAKE_AMB" \
    bash "$SCRIPT" 2>/dev/null
if grep -q "fleet_metrics_snapshot" "$FAKE_AMB" 2>/dev/null; then
    ok "4: emits fleet_metrics_snapshot event to ambient.jsonl"
else
    err "4: no fleet_metrics_snapshot event found in ambient.jsonl"
fi

# Test 5: event has all required fields
EVENT=$(grep "fleet_metrics_snapshot" "$FAKE_AMB" | tail -1)
_missing=""
for field in ts kind ship_rate_24h waste_rate_24h cycle_time_p50_h active_gaps p0_count; do
    if ! echo "$EVENT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert '$field' in d, '$field missing'" 2>/dev/null; then
        _missing="$_missing $field"
    fi
done
if [[ -z "$_missing" ]]; then
    ok "5: event has all required fields (ts, kind, ship_rate_24h, waste_rate_24h, cycle_time_p50_h, active_gaps, p0_count)"
else
    err "5: event missing fields:$_missing"
fi

# Test 6: ship_rate_24h is numeric (float)
if [[ -n "$EVENT" ]]; then
    _rate=$(echo "$EVENT" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d['ship_rate_24h']; assert isinstance(v, (int, float)), f'not numeric: {v}'; print(v)" 2>/dev/null || echo "FAIL")
    if [[ "$_rate" != "FAIL" ]]; then
        ok "6: ship_rate_24h is numeric (got: $_rate)"
    else
        err "6: ship_rate_24h is not numeric"
    fi
else
    err "6: no event to check ship_rate_24h"
fi

# Test 7: --dry-run suppresses ambient write
DRY_AMB="$TMP/dry-ambient.jsonl"
touch "$DRY_AMB"
REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$DRY_AMB" \
    bash "$SCRIPT" --dry-run 2>/dev/null
if [[ ! -s "$DRY_AMB" ]]; then
    ok "7: --dry-run suppresses ambient.jsonl write"
else
    err "7: --dry-run still wrote to ambient.jsonl"
fi

# Test 8: --json outputs valid JSON to stdout with all required fields
JSON_OUT=$(REPO_ROOT="$REPO_ROOT" CHUMP_AMBIENT_LOG="$TMP/json-ambient.jsonl" \
    bash "$SCRIPT" --json 2>/dev/null)
_json_ok=$(echo "$JSON_OUT" | python3 -c "
import json, sys
try:
    text = sys.stdin.read()
    # handle both compact and pretty-printed output
    d = json.loads(text)
    required = ['ts','kind','ship_rate_24h','waste_rate_24h','cycle_time_p50_h','active_gaps','p0_count']
    missing = [f for f in required if f not in d]
    if d.get('kind') != 'fleet_metrics_snapshot':
        print('bad-kind')
    elif missing:
        print('missing:' + ','.join(missing))
    else:
        print('ok')
except Exception as e:
    print(f'parse-error:{e}')
" 2>/dev/null || echo "error")
if [[ "$_json_ok" == "ok" ]]; then
    ok "8: --json outputs valid JSON with all required fields"
else
    err "8: --json check failed: $_json_ok"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
