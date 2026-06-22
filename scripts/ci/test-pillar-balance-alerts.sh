#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh:
#  1. Script exists and is executable
#  2. All pillars balanced → exits 0, prints OK
#  3. Underweight pillar (count=0) → pillar_balance_alert emitted, exits 1
#  4. Alert JSON has required schema fields: ts, kind, pillar, count, floor, total_pickable
#  5. Underweight at count=1 (still below floor=2) → alert fires
#  6. Exactly at floor (count=2) → no alert
#  7. CHUMP_PILLAR_BALANCE_CHECK=0 → disabled, exits 0
#  8. Overweight pillar (>50% of total) → pillar_balance_overweight emitted, exits 1
#  9. Overweight JSON has required fields: ts, kind, pillar, count, pct, total_pickable
# 10. CHUMP_AMBIENT_LOG env var respected (events written to custom path)
# 11. Empty gap list → all pillars at 0, four alerts emitted
# 12. Script handles missing python3 gracefully (skip if python3 absent)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-902 pillar-balance-check smoke tests ==="
echo

# ── 1. Script exists and is executable ───────────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh missing or not executable at $SCRIPT"
    echo "Remaining tests require the script — aborting." >&2
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a stub chump binary that serves canned JSON for 'gap list --status open --json'
make_stub() {
    local name="$1"
    local json="$2"
    local stub_dir="$TMP/stub-$name"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/chump" << STUB
#!/usr/bin/env bash
# Stub chump: returns canned gap list JSON
if [[ "\$1" == "gap" && "\$2" == "list" ]]; then
    printf '%s\n' '$json'
    exit 0
fi
exit 0
STUB
    chmod +x "$stub_dir/chump"
    echo "$stub_dir/chump"
}

run_check() {
    local stub_bin="$1"
    local ambient="$2"
    local extra_env="${3:-}"
    local rc=0
    env CHUMP_BIN="$stub_bin" \
        CHUMP_AMBIENT_LOG="$ambient" \
        CHUMP_PILLAR_FLOOR=2 \
        CHUMP_PILLAR_OVERWEIGHT_PCT=50 \
        $extra_env \
        bash "$SCRIPT" >"$TMP/stdout.txt" 2>"$TMP/stderr.txt" || rc=$?
    echo "$rc"
}

# Canned JSON helpers: build gap objects
# Fields: id, title, priority, effort, acceptance_criteria, depends_on
gap() {
    local id="$1" title="$2" priority="$3" effort="$4" ac="${5:-some AC}" deps="${6:-[]}"
    printf '{"id":"%s","title":"%s","priority":"%s","effort":"%s","acceptance_criteria":"%s","depends_on":"%s","status":"open"}' \
        "$id" "$title" "$priority" "$effort" "$ac" "$deps"
}

# ── Balanced JSON: 2+ gaps per pillar ─────────────────────────────────────────
BALANCED_JSON="[
$(gap EFFECTIVE-001 "EFFECTIVE: add e2e tests" P1 s),
$(gap EFFECTIVE-002 "EFFECTIVE: user dashboard" P0 xs),
$(gap CREDIBLE-001 "CREDIBLE: metrics endpoint" P1 s),
$(gap CREDIBLE-002 "CREDIBLE: trace collector" P0 m),
$(gap RESILIENT-001 "RESILIENT: retry logic" P1 xs),
$(gap RESILIENT-002 "RESILIENT: circuit breaker" P0 s),
$(gap ZERO-001 "ZERO-WASTE: remove dead code" P1 xs),
$(gap ZERO-002 "ZERO-WASTE: dedup migrations" P0 s)
]"

# ── 2. All pillars balanced → exit 0, prints OK ───────────────────────────────
AMB2="$TMP/ambient-2.jsonl"
rc2=$(run_check "$(make_stub bal "$BALANCED_JSON")" "$AMB2")
if [[ "$rc2" == "0" ]]; then
    ok "balanced pillars → exit 0"
else
    fail "balanced pillars unexpectedly non-zero (rc=$rc2; stdout=$(cat "$TMP/stdout.txt"))"
fi
if grep -q "OK" "$TMP/stdout.txt" 2>/dev/null; then
    ok "balanced output contains 'OK'"
else
    fail "balanced output missing 'OK' (got: $(cat "$TMP/stdout.txt"))"
fi

# ── 3. Underweight pillar (EFFECTIVE=0) → alert fires, exit 1 ─────────────────
UNDER_JSON="[
$(gap CREDIBLE-001 "CREDIBLE: metrics" P1 s),
$(gap CREDIBLE-002 "CREDIBLE: trace" P0 xs),
$(gap RESILIENT-001 "RESILIENT: retry" P1 xs),
$(gap RESILIENT-002 "RESILIENT: breaker" P0 s),
$(gap ZERO-001 "ZERO-WASTE: cleanup" P1 xs),
$(gap ZERO-002 "ZERO-WASTE: dedup" P0 s)
]"
AMB3="$TMP/ambient-3.jsonl"
rc3=$(run_check "$(make_stub under "$UNDER_JSON")" "$AMB3")
if [[ "$rc3" == "1" ]]; then
    ok "underweight pillar (EFFECTIVE=0) → exit 1"
else
    fail "underweight pillar did not exit 1 (rc=$rc3)"
fi
if [[ -f "$AMB3" ]] && grep -q "pillar_balance_alert" "$AMB3"; then
    ok "pillar_balance_alert emitted to ambient.jsonl"
else
    fail "pillar_balance_alert not found in ambient.jsonl"
fi
if grep -q "EFFECTIVE" "$AMB3" 2>/dev/null; then
    ok "alert names the underweight pillar (EFFECTIVE)"
else
    fail "alert does not name pillar EFFECTIVE"
fi

# ── 4. Alert JSON schema: ts, kind, pillar, count, floor, total_pickable ───────
ALERT_LINE="$(grep "pillar_balance_alert" "$AMB3" | head -1)"
for field in "\"ts\"" "\"kind\"" "\"pillar\"" "\"count\"" "\"floor\"" "\"total_pickable\""; do
    if echo "$ALERT_LINE" | grep -q "$field"; then
        ok "alert JSON has field $field"
    else
        fail "alert JSON missing field $field (line: $ALERT_LINE)"
    fi
done

# ── 5. Underweight at count=1 (below floor=2) → alert fires ───────────────────
UNDER1_JSON="[
$(gap EFFECTIVE-001 "EFFECTIVE: one gap" P1 s),
$(gap CREDIBLE-001 "CREDIBLE: gap1" P1 s),
$(gap CREDIBLE-002 "CREDIBLE: gap2" P0 xs),
$(gap RESILIENT-001 "RESILIENT: gap1" P1 xs),
$(gap RESILIENT-002 "RESILIENT: gap2" P0 s),
$(gap ZERO-001 "ZERO-WASTE: gap1" P1 xs),
$(gap ZERO-002 "ZERO-WASTE: gap2" P0 s)
]"
AMB5="$TMP/ambient-5.jsonl"
rc5=$(run_check "$(make_stub under1 "$UNDER1_JSON")" "$AMB5")
if [[ "$rc5" == "1" ]]; then
    ok "count=1 pillar (below floor=2) → exit 1"
else
    fail "count=1 pillar did not trigger alert (rc=$rc5)"
fi

# ── 6. Pillar at exactly floor=2 → no alert ───────────────────────────────────
AT_FLOOR_JSON="[
$(gap EFFECTIVE-001 "EFFECTIVE: gap1" P1 s),
$(gap EFFECTIVE-002 "EFFECTIVE: gap2" P0 xs),
$(gap CREDIBLE-001 "CREDIBLE: gap1" P1 s),
$(gap CREDIBLE-002 "CREDIBLE: gap2" P0 xs),
$(gap RESILIENT-001 "RESILIENT: gap1" P1 xs),
$(gap RESILIENT-002 "RESILIENT: gap2" P0 s),
$(gap ZERO-001 "ZERO-WASTE: gap1" P1 xs),
$(gap ZERO-002 "ZERO-WASTE: gap2" P0 s)
]"
AMB6="$TMP/ambient-6.jsonl"
rc6=$(run_check "$(make_stub atfloor "$AT_FLOOR_JSON")" "$AMB6")
if [[ "$rc6" == "0" ]]; then
    ok "pillar at exactly floor (count=2) → exit 0, no alert"
else
    fail "pillar at floor should not alert (rc=$rc6)"
fi
if [[ -f "$AMB6" ]] && grep -q "pillar_balance_alert" "$AMB6"; then
    fail "spurious pillar_balance_alert at exactly floor"
else
    ok "no spurious alert at floor boundary"
fi

# ── 7. CHUMP_PILLAR_BALANCE_CHECK=0 → disabled, exit 0 ────────────────────────
AMB7="$TMP/ambient-7.jsonl"
rc7=0
env CHUMP_BIN="$(make_stub dis "$UNDER_JSON")" \
    CHUMP_AMBIENT_LOG="$AMB7" \
    CHUMP_PILLAR_BALANCE_CHECK=0 \
    bash "$SCRIPT" >"$TMP/out7.txt" 2>/dev/null || rc7=$?
if [[ "$rc7" == "0" ]]; then
    ok "CHUMP_PILLAR_BALANCE_CHECK=0 → exit 0 (disabled)"
else
    fail "CHUMP_PILLAR_BALANCE_CHECK=0 did not disable check (rc=$rc7)"
fi

# ── 8. Overweight pillar (>50% of total) → pillar_balance_overweight emitted ──
# 6 CREDIBLE out of 8 total pickable = 75% > 50%
OW_JSON="[
$(gap CREDIBLE-001 "CREDIBLE: g1" P1 xs),
$(gap CREDIBLE-002 "CREDIBLE: g2" P0 s),
$(gap CREDIBLE-003 "CREDIBLE: g3" P1 xs),
$(gap CREDIBLE-004 "CREDIBLE: g4" P0 s),
$(gap CREDIBLE-005 "CREDIBLE: g5" P1 xs),
$(gap CREDIBLE-006 "CREDIBLE: g6" P0 s),
$(gap RESILIENT-001 "RESILIENT: g1" P1 xs),
$(gap RESILIENT-002 "RESILIENT: g2" P0 s)
]"
AMB8="$TMP/ambient-8.jsonl"
rc8=$(run_check "$(make_stub ow "$OW_JSON")" "$AMB8")
if [[ "$rc8" != "0" ]]; then
    ok "overweight pillar → exit non-zero"
else
    fail "overweight pillar did not trigger non-zero exit (rc=$rc8)"
fi
if [[ -f "$AMB8" ]] && grep -q "pillar_balance_overweight" "$AMB8"; then
    ok "pillar_balance_overweight emitted to ambient.jsonl"
else
    fail "pillar_balance_overweight not found in ambient.jsonl"
fi

# ── 9. Overweight JSON schema: ts, kind, pillar, count, pct, total_pickable ───
OW_LINE="$(grep "pillar_balance_overweight" "$AMB8" 2>/dev/null | head -1)"
for field in "\"ts\"" "\"kind\"" "\"pillar\"" "\"count\"" "\"pct\"" "\"total_pickable\""; do
    if echo "$OW_LINE" | grep -q "$field"; then
        ok "overweight JSON has field $field"
    else
        fail "overweight JSON missing field $field (line: $OW_LINE)"
    fi
done

# ── 10. CHUMP_AMBIENT_LOG env var is respected ─────────────────────────────────
CUSTOM_AMB="$TMP/custom-dir/my-ambient.jsonl"
AMB10="$CUSTOM_AMB"
# Note: the script should mkdir -p the dirname before writing
rc10=0
env CHUMP_BIN="$(make_stub amb "$UNDER_JSON")" \
    CHUMP_AMBIENT_LOG="$AMB10" \
    CHUMP_PILLAR_FLOOR=2 \
    CHUMP_PILLAR_OVERWEIGHT_PCT=50 \
    bash "$SCRIPT" >/dev/null 2>/dev/null || rc10=$?
if [[ -f "$CUSTOM_AMB" ]] && grep -q "pillar_balance_alert" "$CUSTOM_AMB"; then
    ok "CHUMP_AMBIENT_LOG respected — events written to custom path"
else
    fail "CHUMP_AMBIENT_LOG not respected (file: ${CUSTOM_AMB}; exists=$(test -f "$CUSTOM_AMB" && echo yes || echo no))"
fi

# ── 11. Empty gap list → all 4 pillars alert ──────────────────────────────────
EMPTY_JSON="[]"
AMB11="$TMP/ambient-11.jsonl"
rc11=$(run_check "$(make_stub empty "$EMPTY_JSON")" "$AMB11")
if [[ "$rc11" != "0" ]]; then
    ok "empty gap list → exit non-zero"
else
    fail "empty gap list should have triggered underweight alerts (rc=$rc11)"
fi
if [[ -f "$AMB11" ]]; then
    alert_count=0
    alert_count=$(grep -c "pillar_balance_alert" "$AMB11" 2>/dev/null) || alert_count=0
    if [[ "$alert_count" -ge 4 ]]; then
        ok "empty gap list → 4 pillar_balance_alert events (got $alert_count)"
    else
        fail "empty gap list → expected >=4 alerts, got $alert_count"
    fi
else
    fail "empty gap list → ambient.jsonl not created"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
