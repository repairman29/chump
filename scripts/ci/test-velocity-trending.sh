#!/usr/bin/env bash
# test-velocity-trending.sh — INFRA-901
#
# 8 tests verifying velocity-trending.sh with synthetic fixture data.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/ops/velocity-trending.sh"

pass=0
fail=0
ok()  { echo "  PASS $1"; pass=$((pass + 1)); }
err() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "=== test-velocity-trending.sh ==="

# Test 1: script exists and is executable
if [[ -x "$SCRIPT" ]]; then
    ok "1: velocity-trending.sh exists and is executable"
else
    err "1: velocity-trending.sh missing or not executable"
    exit 1
fi

# Test 2: kind=velocity_trend_computed registered in EVENT_REGISTRY
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "velocity_trend_computed" "$REGISTRY" 2>/dev/null; then
    ok "2: velocity_trend_computed registered in EVENT_REGISTRY.yaml"
else
    err "2: velocity_trend_computed not found in EVENT_REGISTRY.yaml"
fi

# Test 3: INFRA-901 referenced in script
if grep -q "INFRA-901" "$SCRIPT" 2>/dev/null; then
    ok "3: INFRA-901 referenced in velocity-trending.sh"
else
    err "3: INFRA-901 not referenced in velocity-trending.sh"
fi

# ── Fixture helpers ───────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Write N fleet_metrics_snapshot events to a fake ambient.jsonl
# Arguments: file, days_back_start, days_back_end, ship_rate, waste_rate
write_snapshots() {
    local amb="$1" start_days="$2" end_days="$3" ship="$4" waste="$5"
    local d
    for d in $(seq "$start_days" -1 "$end_days"); do
        ts=$(python3 -c "
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc)
t = now - timedelta(days=$d, hours=2)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
        printf '{"ts":"%s","kind":"fleet_metrics_snapshot","ship_rate_24h":%s,"waste_rate_24h":%s,"cycle_time_p50_h":1.5,"active_gaps":10,"p0_count":1,"window_h":24,"host":"test"}\n' \
            "$ts" "$ship" "$waste" >> "$amb"
    done
}

# ── Test 4: emits velocity_trend_computed event to ambient.jsonl ─────────────
AMB4="$TMP/t4-ambient.jsonl"
write_snapshots "$AMB4" 6 0 0.75 0.10
CHUMP_AMBIENT_LOG="$AMB4" REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" >/dev/null 2>&1
if grep -q "velocity_trend_computed" "$AMB4" 2>/dev/null; then
    ok "4: emits velocity_trend_computed to ambient.jsonl"
else
    err "4: no velocity_trend_computed event found in ambient.jsonl"
fi

# ── Test 5: event has required fields ────────────────────────────────────────
EVENT5=$(grep "velocity_trend_computed" "$AMB4" | tail -1)
_missing=""
for field in ts kind window_days ship_rate_7d waste_rate_7d trend days_sampled; do
    if ! echo "$EVENT5" | python3 -c "import json,sys; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
        _missing="$_missing $field"
    fi
done
if [[ -z "$_missing" ]]; then
    ok "5: event has all required fields (ts, kind, window_days, ship_rate_7d, waste_rate_7d, trend, days_sampled)"
else
    err "5: event missing fields:$_missing"
fi

# ── Test 6: trend=improving when recent ship_rate > prior ────────────────────
# Prior 4 days: ship_rate=0.30; last 3 days: ship_rate=0.80 → improving
AMB6="$TMP/t6-ambient.jsonl"
write_snapshots "$AMB6" 6 3 0.30 0.20   # prior 4 days (days 6,5,4,3 back)
write_snapshots "$AMB6" 2 0 0.80 0.10   # last 3 days  (days 2,1,0 back)
OUT6=$(CHUMP_AMBIENT_LOG="$AMB6" REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --json 2>/dev/null | grep "velocity_trend_computed" | tail -1)
TREND6=$(echo "$OUT6" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('trend','?'))" 2>/dev/null || echo "?")
if [[ "$TREND6" == "improving" ]]; then
    ok "6: trend=improving when recent 3d ship_rate >> prior 4d"
else
    err "6: expected improving, got: $TREND6"
fi

# ── Test 7: trend=degrading when recent ship_rate < prior ─────────────────────
# Prior 4 days: ship_rate=0.80; last 3 days: ship_rate=0.20 → degrading
AMB7="$TMP/t7-ambient.jsonl"
write_snapshots "$AMB7" 6 3 0.80 0.10
write_snapshots "$AMB7" 2 0 0.20 0.30
OUT7=$(CHUMP_AMBIENT_LOG="$AMB7" REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --json 2>/dev/null | grep "velocity_trend_computed" | tail -1)
TREND7=$(echo "$OUT7" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('trend','?'))" 2>/dev/null || echo "?")
if [[ "$TREND7" == "degrading" ]]; then
    ok "7: trend=degrading when recent 3d ship_rate << prior 4d"
else
    err "7: expected degrading, got: $TREND7"
fi

# ── Test 8: --dry-run suppresses ambient write ────────────────────────────────
AMB8="$TMP/t8-ambient.jsonl"
write_snapshots "$AMB8" 3 0 0.60 0.15
# Count lines before
lines_before=$(wc -l < "$AMB8" | tr -d ' ')
CHUMP_AMBIENT_LOG="$AMB8" REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --dry-run >/dev/null 2>/dev/null || true
lines_after=$(wc -l < "$AMB8" | tr -d ' ')
if [[ "$lines_before" -eq "$lines_after" ]]; then
    ok "8: --dry-run suppresses velocity_trend_computed write to ambient.jsonl"
else
    err "8: --dry-run still appended to ambient.jsonl ($lines_before → $lines_after)"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
