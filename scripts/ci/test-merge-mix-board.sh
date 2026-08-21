#!/usr/bin/env bash
# test-merge-mix-board.sh — CREDIBLE-296: merge-mix board fixture tests
#
# Tests (offline — no gh network calls):
#   1. Correct classification + percentage computation across the 3 buckets
#   2. Metrics JSONL row has all required fields
#   3. Waste-over-threshold alarm fires when reconcile-waste% exceeds --threshold
#   4. Alarm does NOT fire when reconcile-waste% is under threshold
#   5. CHUMP_MMB_DATE injects a deterministic date into the JSONL row
#   6. --window arg is accepted without error
#
# All tests are offline: fixture data is fed via CHUMP_MMB_FIXTURE env var;
# no live gh calls are made.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dispatch/merge-mix-board.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$SCRIPT" ]] || fail "merge-mix-board.sh not found at $SCRIPT"

TMP="$(mktemp -d -t test-merge-mix-board.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

METRICS_DIR="$TMP/metrics"
AMBIENT="$TMP/ambient.jsonl"
FIXTURE="$TMP/fixture.json"

# ── Build fixture ──────────────────────────────────────────────────────────────
# 4 PRs: 2 reconcile-waste, 1 user-value, 1 self-maint → 50% reconcile-waste.
cat > "$FIXTURE" <<'JSON'
[
  {"number": 4086, "title": "gaps(INFRA-1387): reconcile stale per-file gap YAML — already shipped via #4084"},
  {"number": 4084, "title": "docs(INFRA-1387): e2e-golden-path disposition — KEEP-ADVISORY"},
  {"number": 4090, "title": "feat(product): add customer-facing export button"},
  {"number": 4091, "title": "fix(INFRA-500): tighten curator heartbeat interval"}
]
JSON

BASE_ENV=(
    env
    CHUMP_MMB_FIXTURE="$FIXTURE"
    CHUMP_MMB_DATE="2026-08-21"
    CHUMP_METRICS_DIR="$METRICS_DIR"
    CHUMP_AMBIENT_LOG="$AMBIENT"
)

# ── Test 1: Correct classification + percentages ──────────────────────────────
OUT1="$("${BASE_ENV[@]}" bash "$SCRIPT" --json --dry-run --threshold 40 2>/dev/null)"

if echo "$OUT1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['total_prs']==4, f\"total_prs: expected 4, got {d['total_prs']}\"
assert d['reconcile_waste_count']==2, f\"reconcile_waste_count: expected 2, got {d['reconcile_waste_count']}\"
assert d['user_value_count']==1, f\"user_value_count: expected 1, got {d['user_value_count']}\"
assert d['self_maint_count']==1, f\"self_maint_count: expected 1, got {d['self_maint_count']}\"
assert abs(d['reconcile_waste_pct']-50.0)<0.01, f\"reconcile_waste_pct: expected 50.0, got {d['reconcile_waste_pct']}\"
" 2>/dev/null; then
    pass "Test 1: classification + percentages computed correctly (2 reconcile-waste, 1 user-value, 1 self-maint => 50%)"
else
    fail "Test 1: unexpected result: $OUT1"
fi

# ── Test 2: Metrics file written with correct fields ──────────────────────────
"${BASE_ENV[@]}" bash "$SCRIPT" --json --threshold 40 2>/dev/null > /dev/null

METRICS_FILE="$METRICS_DIR/merge-mix-board.jsonl"
if [[ -f "$METRICS_FILE" ]]; then
    ROW="$(tail -1 "$METRICS_FILE")"
    FIELDS_OK="$(echo "$ROW" | python3 -c "
import json,sys
d=json.load(sys.stdin)
required=['date','total_prs','user_value_count','self_maint_count','reconcile_waste_count','user_value_pct','self_maint_pct','reconcile_waste_pct']
missing=[k for k in required if k not in d]
print('OK' if not missing else 'MISSING:'+','.join(missing))
" 2>/dev/null || echo "parse_error")"
    if [[ "$FIELDS_OK" == "OK" ]]; then
        pass "Test 2: metrics JSONL row has all required fields"
    else
        fail "Test 2: metrics row missing fields: $FIELDS_OK (row: $ROW)"
    fi
else
    fail "Test 2: metrics file not created at $METRICS_FILE"
fi

# ── Test 3: Alarm fires when reconcile-waste% exceeds threshold ───────────────
rm -f "$AMBIENT"
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 40 2>/dev/null > /dev/null
if [[ -f "$AMBIENT" ]] && grep -q "merge_mix_waste_threshold_breach" "$AMBIENT"; then
    pass "Test 3: waste-over-threshold alarm fires at 50% reconcile-waste with threshold=40"
else
    fail "Test 3: expected merge_mix_waste_threshold_breach in ambient.jsonl (file: $AMBIENT)"
fi

# ── Test 4: Alarm does NOT fire when under threshold ──────────────────────────
rm -f "$AMBIENT"
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 90 2>/dev/null > /dev/null
if [[ -f "$AMBIENT" ]] && grep -q "merge_mix_waste_threshold_breach" "$AMBIENT"; then
    fail "Test 4: alarm should NOT fire at 50% reconcile-waste with threshold=90"
else
    pass "Test 4: no alarm when reconcile-waste% (50%) is under threshold (90%)"
fi

# ── Test 5: CHUMP_MMB_DATE injects deterministic date into JSONL ──────────────
rm -f "$METRICS_FILE"
"${BASE_ENV[@]}" bash "$SCRIPT" --json --threshold 40 2>/dev/null > /dev/null
DATE_IN_ROW="$(tail -1 "$METRICS_FILE" | python3 -c "import json,sys; print(json.load(sys.stdin)['date'])" 2>/dev/null || echo "?")"
if [[ "$DATE_IN_ROW" == "2026-08-21" ]]; then
    pass "Test 5: CHUMP_MMB_DATE injected correctly into JSONL row (got $DATE_IN_ROW)"
else
    fail "Test 5: expected date=2026-08-21, got $DATE_IN_ROW"
fi

# ── Test 6: --window arg accepted without error ───────────────────────────────
if "${BASE_ENV[@]}" bash "$SCRIPT" --window 10 --json --dry-run --threshold 40 2>/dev/null | python3 -c "import json,sys; json.load(sys.stdin)" &>/dev/null; then
    pass "Test 6: --window N accepted"
else
    fail "Test 6: --window N rejected or produced invalid JSON"
fi

echo ""
echo "All CREDIBLE-296 merge-mix-board checks passed (6/6)."
