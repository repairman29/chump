#!/usr/bin/env bash
# test-race-control.sh — CREDIBLE-296: Race Control merge-mix board fixture tests
#
# Depth tier: offline fixture tests (title/label → expected class), no gh
# network calls — same class of coverage as test-autonomous-ship-rate.sh.
# Gaps not covered (green-not-covered rule): does not exercise the live `gh
# api` fetch path, the systemd timer/service files themselves (no systemd in
# CI sandbox — verified by hand via VERIFY-LIVE in the shipping PR), or the
# organ-reconcile revival path (RESILIENT-366's roll-call test covers the
# manifest/installer coherence half separately).
#
# Tests:
#   1. Classification: each sample title lands in its expected bucket
#      (reconcile-waste / self-maintenance / user-value)
#   2. Percentages sum to 100 and counts match the fixture size
#   3. race_control_mix ambient event emitted on every run (not just alarm runs)
#   4. race_control_waste_alarm fires (+ non-zero exit) when reconcile-waste%
#      exceeds --threshold
#   5. No alarm (+ zero exit) when reconcile-waste% is under threshold
#   6. Metrics JSONL row has all required fields
#   7. Explicit label (reconcile-waste/user-value/self-maintenance) wins over
#      title heuristic
#   8. CHUMP_RACE_DATE injects a deterministic date into the JSONL row
#
# All tests are offline: fixture data is fed via CHUMP_RACE_FIXTURE env var;
# no live gh calls are made.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/race-control.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$SCRIPT" ]] || fail "race-control.sh not found at $SCRIPT"
[[ -x "$SCRIPT" ]] || fail "race-control.sh not executable"

TMP="$(mktemp -d -t test-race-control.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

METRICS_DIR="$TMP/metrics"
AMBIENT="$TMP/ambient.jsonl"
FIXTURE="$TMP/fixture.json"

BASE_ENV=(
    env
    CHUMP_RACE_FIXTURE="$FIXTURE"
    CHUMP_RACE_DATE="2026-08-21"
    CHUMP_METRICS_DIR="$METRICS_DIR"
    CHUMP_AMBIENT_LOG="$AMBIENT"
)

# ── Test 1+2: classification rules (title → expected class) ──────────────────
# 6 PRs: 3 reconcile-waste, 2 self-maintenance, 1 user-value → 50/33.3/16.7%
cat > "$FIXTURE" <<'JSON'
[
  {"number": 1, "title": "gaps(INFRA-1502): reconcile stale per-file gap YAML — already shipped via #4087", "labels": []},
  {"number": 2, "title": "fix(RESILIENT-366): backlog-sync writer roll-call — close the roster/manifest coherence gap", "labels": []},
  {"number": 3, "title": "docs(INFRA-1386): fix stale 'pending decision' comment — all 3 gates already dispositioned", "labels": []},
  {"number": 4, "title": "docs(governance): add Role Registry — operational ownership map", "labels": []},
  {"number": 5, "title": "chore(ci): tighten clippy lint", "labels": []},
  {"number": 6, "title": "feat(product): add onboarding flow", "labels": []}
]
JSON

OUT1="$("${BASE_ENV[@]}" bash "$SCRIPT" --json --dry-run 2>/dev/null || true)"
if echo "$OUT1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['window']==6, f\"window: expected 6, got {d['window']}\"
assert d['reconcile_waste_count']==3, f\"reconcile_waste_count: expected 3, got {d['reconcile_waste_count']}\"
assert d['self_maintenance_count']==2, f\"self_maintenance_count: expected 2, got {d['self_maintenance_count']}\"
assert d['user_value_count']==1, f\"user_value_count: expected 1, got {d['user_value_count']}\"
" 2>/dev/null; then
    pass "Test 1: classification — 3 reconcile-waste, 2 self-maintenance, 1 user-value"
else
    fail "Test 1: unexpected classification: $OUT1"
fi

if echo "$OUT1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
total=round(d['reconcile_waste_pct']+d['self_maintenance_pct']+d['user_value_pct'],1)
assert abs(total-100.0)<0.2, f\"percentages sum to {total}, not ~100\"
"; then
    pass "Test 2: percentages sum to ~100"
else
    fail "Test 2: percentages did not sum to 100 ($OUT1)"
fi

# ── Test 3: race_control_mix emitted on every run ─────────────────────────────
rm -f "$AMBIENT"
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 90 2>/dev/null > /dev/null || true
if grep -q '"kind":"race_control_mix"' "$AMBIENT" 2>/dev/null; then
    pass "Test 3: race_control_mix emitted to ambient.jsonl on every run"
else
    fail "Test 3: expected race_control_mix in $AMBIENT"
fi

# ── Test 4: alarm fires + non-zero exit when over threshold ──────────────────
rm -f "$AMBIENT"
set +e
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 30 2>/dev/null > /dev/null
EXIT4=$?
set -e
if [[ "$EXIT4" -ne 0 ]] && grep -q '"kind":"race_control_waste_alarm"' "$AMBIENT" 2>/dev/null; then
    pass "Test 4: race_control_waste_alarm fires + non-zero exit (50% > 30% threshold)"
else
    fail "Test 4: expected alarm + non-zero exit (got exit=$EXIT4, ambient=$(cat "$AMBIENT" 2>/dev/null))"
fi

# ── Test 5: no alarm + zero exit when under threshold ─────────────────────────
rm -f "$AMBIENT"
set +e
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 90 2>/dev/null > /dev/null
EXIT5=$?
set -e
if [[ "$EXIT5" -eq 0 ]] && ! grep -q '"kind":"race_control_waste_alarm"' "$AMBIENT" 2>/dev/null; then
    pass "Test 5: no alarm + zero exit when reconcile-waste under threshold (50% < 90%)"
else
    fail "Test 5: expected no alarm + zero exit (got exit=$EXIT5)"
fi

# ── Test 6: metrics JSONL row has required fields ─────────────────────────────
METRICS_FILE="$METRICS_DIR/race-control.jsonl"
if [[ -f "$METRICS_FILE" ]]; then
    ROW="$(tail -1 "$METRICS_FILE")"
    FIELDS_OK="$(echo "$ROW" | python3 -c "
import json,sys
d=json.load(sys.stdin)
required=['date','window','user_value_pct','self_maintenance_pct','reconcile_waste_pct']
missing=[k for k in required if k not in d]
print('OK' if not missing else 'MISSING:'+','.join(missing))
" 2>/dev/null || echo "parse_error")"
    if [[ "$FIELDS_OK" == "OK" ]]; then
        pass "Test 6: metrics JSONL row has all required fields"
    else
        fail "Test 6: metrics row missing fields: $FIELDS_OK (row: $ROW)"
    fi
else
    fail "Test 6: metrics file not created at $METRICS_FILE"
fi

# ── Test 7: explicit label wins over title heuristic ──────────────────────────
cat > "$FIXTURE" <<'JSON'
[
  {"number": 10, "title": "feat(product): looks like user-value but labeled reconcile-waste", "labels": ["reconcile-waste"]}
]
JSON
OUT7="$("${BASE_ENV[@]}" bash "$SCRIPT" --json --dry-run 2>/dev/null || true)"
if echo "$OUT7" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['reconcile_waste_count']==1, f\"expected label to force reconcile-waste, got {d}\"
"; then
    pass "Test 7: explicit PR label overrides title heuristic"
else
    fail "Test 7: label override failed: $OUT7"
fi

# ── Test 8: CHUMP_RACE_DATE injects deterministic date ─────────────────────────
cat > "$FIXTURE" <<'JSON'
[{"number": 1, "title": "feat(product): x", "labels": []}]
JSON
rm -f "$METRICS_FILE"
"${BASE_ENV[@]}" bash "$SCRIPT" --json 2>/dev/null > /dev/null
DATE_IN_ROW="$(tail -1 "$METRICS_FILE" | python3 -c "import json,sys; print(json.load(sys.stdin)['date'])" 2>/dev/null || echo "?")"
if [[ "$DATE_IN_ROW" == "2026-08-21" ]]; then
    pass "Test 8: CHUMP_RACE_DATE injected correctly into JSONL row (got $DATE_IN_ROW)"
else
    fail "Test 8: expected date=2026-08-21, got $DATE_IN_ROW"
fi

# ── Test 9: merge-mix-board is retired, race-control is canonical (INFRA-3844) ──
[[ ! -f "$REPO_ROOT/scripts/dispatch/merge-mix-board.sh" ]] \
    || fail "Test 9: scripts/dispatch/merge-mix-board.sh should have been retired"
[[ ! -f "$REPO_ROOT/scripts/ci/test-merge-mix-board.sh" ]] \
    || fail "Test 9: scripts/ci/test-merge-mix-board.sh should have been retired"
grep -q "merge_mix_waste_threshold_breach" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    && fail "Test 9: merge_mix_waste_threshold_breach must not be registered — race_control_waste_alarm is canonical"
grep -q "race-control.jsonl" "$REPO_ROOT/scripts/dispatch/fleet-status.sh" \
    || fail "Test 9: fleet-status.sh should read race-control.jsonl, not merge-mix-board.jsonl"
grep -q "self_maintenance_pct" "$REPO_ROOT/scripts/dispatch/fleet-status.sh" \
    || fail "Test 9: fleet-status.sh should use the unified self_maintenance_pct field name"
pass "Test 9: merge-mix-board retired, race-control is the sole canonical emitter"

echo ""
echo "All CREDIBLE-296 race-control checks passed (9/9)."
