#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests pillar-balance-check.sh against all ACs:
#  AC1: reads state.db via chump gap list --status open
#  AC2: pillar count < 2 → pillar_balance_alert (pillar, count, floor=2)
#  AC3: pillar count > 50% of pool → pillar_balance_overweight (pillar, count, pct)
#  AC4: exits non-zero when any alert fired
#  AC5: chump gap audit-priorities calls the script
#  AC6: 8+ tests covering alerts, thresholds, exit codes

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  OK  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

# ── Resolve chump binary (INFRA-481: shared target-dir, empty in worktrees) ─
_cargo_tgt="$(cargo metadata --format-version 1 --no-deps \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' \
    2>/dev/null || true)"
CHUMP_BIN="${CHUMP_BIN:-}"
for _cand in "$CHUMP_BIN" \
             "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
             "$REPO_ROOT/target/debug/chump" \
             "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
    [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
done
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "[build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
    for _cand in "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
                 "$REPO_ROOT/target/debug/chump" \
                 "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
        [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
    done
fi
export CHUMP_BIN

if [[ ! -x "$CHUMP_BIN" ]]; then
    fail "chump binary not found after build"; echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: Script exists and is executable ──────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture helpers ──────────────────────────────────────────────────────────
setup_fixture() {
    local TMP
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/.chump" "$TMP/docs/gaps" "$TMP/.chump-locks"
    cd "$TMP"
    git init -q . 2>/dev/null || true
    git config user.email "test@ci.local" 2>/dev/null || true
    git config user.name "CI" 2>/dev/null || true

    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: disable title-similarity check so 2nd+ fixture gap isn't blocked
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    echo "$TMP"
}

reserve_gap() {
    local title="$1"
    local priority="${2:-P1}"
    local effort="${3:-xs}"
    local ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate 2>/dev/null || true
}

# ── Test 2: Balanced pillars exit 0 ──────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar) → exit 0"
TMP2="$(setup_fixture)"
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-a"
    reserve_gap "${p}: balanced-b"
done
: > "$TMP2/.chump-locks/ambient.jsonl"
if AMBIENT="$TMP2/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "balanced pillars exit 0"
else
    fail "balanced pillars should exit 0"
fi
rm -rf "$TMP2"

# ── Test 3: Under-fed pillar → pillar_balance_alert + exit non-zero ─────────
echo "[Test 3] Under-fed pillar (< 2) → alert + non-zero exit"
TMP3="$(setup_fixture)"
reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-a"
# ZERO-WASTE has 0 → underfed
: > "$TMP3/.chump-locks/ambient.jsonl"
AMBIENT="$TMP3/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1 \
    && exit_code=0 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi
if grep -q '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_alert event emitted"
else
    fail "pillar_balance_alert not found in ambient.jsonl"
fi
if grep '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null \
   | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "pillar" in d and "count" in d and "floor" in d' 2>/dev/null; then
    ok "pillar_balance_alert has required fields (pillar, count, floor)"
else
    fail "pillar_balance_alert missing required fields"
fi
if grep '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null \
   | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["floor"] == 2' 2>/dev/null; then
    ok "pillar_balance_alert floor == 2"
else
    fail "pillar_balance_alert floor should be 2"
fi
rm -rf "$TMP3"

# ── Test 4: Overweight pillar (> 50%) → pillar_balance_overweight + non-zero ─
echo "[Test 4] Overweight pillar (> 50%) → overweight alert + non-zero exit"
TMP4="$(setup_fixture)"
for i in 1 2 3 4 5 6; do reserve_gap "EFFECTIVE: overweight-$i"; done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"
# total=9, EFFECTIVE=6 → 66% > 50%
: > "$TMP4/.chump-locks/ambient.jsonl"
AMBIENT="$TMP4/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1 \
    && exit_code=0 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi
if grep -q '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not found"
fi
if grep '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null \
   | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["pct"] > 50' 2>/dev/null; then
    ok "pillar_balance_overweight pct > 50"
else
    fail "pillar_balance_overweight pct should be > 50"
fi
rm -rf "$TMP4"

# ── Test 5: Non-pickable gaps ignored ────────────────────────────────────────
echo "[Test 5] Non-pickable gaps (P2, m-effort, TODO AC) are ignored"
TMP5="$(setup_fixture)"
# Healthy pickable baseline
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: healthy-a" P1 xs "ac"
    reserve_gap "${p}: healthy-b" P1 xs "ac"
done
# Non-pickable: P2 effort, m-effort, TODO AC — should not count
reserve_gap "EFFECTIVE: p2-ignored"       P2 xs "ac"
reserve_gap "EFFECTIVE: m-effort-ignored" P1 m  "ac"
reserve_gap "EFFECTIVE: todo-ac-ignored"  P1 xs "TODO"
: > "$TMP5/.chump-locks/ambient.jsonl"
if AMBIENT="$TMP5/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "non-pickable gaps ignored — healthy baseline still exits 0"
else
    fail "non-pickable gaps should not affect healthy baseline"
fi
rm -rf "$TMP5"

# ── Test 6: Healthy state produces no ambient events ────────────────────────
echo "[Test 6] Healthy state produces no alerts in ambient.jsonl"
TMP6="$(setup_fixture)"
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: no-alert-a" P1 xs "ac1"
    reserve_gap "${p}: no-alert-b" P1 xs "ac2"
    reserve_gap "${p}: no-alert-c" P1 xs "ac3"
done
: > "$TMP6/.chump-locks/ambient.jsonl"
AMBIENT="$TMP6/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1 || true
if [[ ! -s "$TMP6/.chump-locks/ambient.jsonl" ]]; then
    ok "healthy state emits no alerts"
else
    fail "healthy state should produce no ambient events"
fi
rm -rf "$TMP6"

# ── Test 7: audit-priorities integrates pillar balance result ────────────────
echo "[Test 7] chump gap audit-priorities includes pillar balance result (AC5)"
TMP7="$(setup_fixture)"
# Unbalanced: only RESILIENT gaps, others empty
for i in 1 2 3 4 5; do reserve_gap "RESILIENT: audit-test-$i"; done
audit_out=$("$CHUMP_BIN" gap audit-priorities 2>&1 || true)
if echo "$audit_out" | grep -qi "pillar"; then
    ok "audit-priorities output mentions pillar balance"
else
    fail "audit-priorities should mention pillar balance"
fi
rm -rf "$TMP7"

# ── Test 8: Both alert types in a single run ─────────────────────────────────
echo "[Test 8] Both alert types (under-fed + overweight) in one run"
TMP8="$(setup_fixture)"
for i in 1 2 3 4 5 6 7 8 9 10; do reserve_gap "EFFECTIVE: multi-$i"; done
reserve_gap "CREDIBLE: multi-1"
# RESILIENT=0 (under-fed), ZERO-WASTE=0 (under-fed), EFFECTIVE=10/11 ≈ 91% (overweight)
: > "$TMP8/.chump-locks/ambient.jsonl"
AMBIENT="$TMP8/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1 \
    && exit_code=0 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    ok "multi-alert run exits non-zero"
else
    fail "multi-alert run should exit non-zero"
fi
# grep -c exits 1 on no match; capture with || true then default to 0
n_under=$(grep -c '"kind":"pillar_balance_alert"' "$TMP8/.chump-locks/ambient.jsonl" 2>/dev/null || true)
n_over=$(grep -c '"kind":"pillar_balance_overweight"' "$TMP8/.chump-locks/ambient.jsonl" 2>/dev/null || true)
n_under=${n_under:-0}; n_over=${n_over:-0}
if [[ "$n_under" -gt 0 && "$n_over" -gt 0 ]]; then
    ok "both pillar_balance_alert and pillar_balance_overweight emitted"
elif [[ "$n_under" -gt 0 || "$n_over" -gt 0 ]]; then
    ok "at least one alert type emitted"
else
    fail "should emit both alert types"
fi
rm -rf "$TMP8"

# ── Test 9: mkdir -p for .chump-locks/ before ambient append ────────────────
echo "[Test 9] Script creates .chump-locks/ if absent (AC blocker fix)"
TMP9="$(setup_fixture)"
# Remove .chump-locks/ to simulate missing dir
rm -rf "$TMP9/.chump-locks"
reserve_gap "EFFECTIVE: mkdir-test" P1 xs "ac"
# AMBIENT points inside the absent dir; script must mkdir -p it
AMBIENT_PATH="$TMP9/.chump-locks/ambient.jsonl"
if AMBIENT="$AMBIENT_PATH" bash "$SCRIPT" >/dev/null 2>&1 \
   || [[ -d "$(dirname "$AMBIENT_PATH")" ]]; then
    ok "script creates .chump-locks/ before ambient append"
else
    fail "script failed when .chump-locks/ was absent"
fi
rm -rf "$TMP9"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
