#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests pillar-balance-check.sh:
#  AC1: reads state.db via chump gap list --status open
#  AC2: pillar count < 2 → kind=pillar_balance_alert with pillar, count, floor=2
#  AC3: pillar count > 50% → kind=pillar_balance_overweight with pillar, count, pct
#  AC4: exits non-zero if any alert fired
#  AC5: chump gap audit-priorities calls the script (integration)
#  AC6: 8+ tests

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve chump binary. INFRA-481: worktrees share a target dir via
# .cargo/config.toml, so $REPO_ROOT/target may be empty — use cargo metadata.
_cargo_tgt=""
_cargo_tgt="$(cargo metadata --format-version 1 --no-deps \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' \
    2>/dev/null || true)"

CHUMP_BIN="${CHUMP_BIN:-}"
for _cand in \
    "$CHUMP_BIN" \
    "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
    "$REPO_ROOT/target/debug/chump" \
    "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
    [ -n "$_cand" ] && [ -x "$_cand" ] && { CHUMP_BIN="$_cand"; break; }
done

if [ -z "$CHUMP_BIN" ] || [ ! -x "$CHUMP_BIN" ]; then
    echo "[build] cargo build --bin chump ..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
    for _cand in \
        "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
        "$REPO_ROOT/target/debug/chump" \
        "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
        [ -n "$_cand" ] && [ -x "$_cand" ] && { CHUMP_BIN="$_cand"; break; }
    done
fi

export CHUMP_BIN

if [ ! -x "$CHUMP_BIN" ]; then
    fail "chump binary not found after build"
    echo "PASS=$PASS  FAIL=$FAIL"
    exit 1
fi

PBS="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: script exists and is executable ──────────────────────────────────
if [ -x "$PBS" ]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture helpers ───────────────────────────────────────────────────────────
setup_test_repo() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump" "$tmp/docs/gaps" "$tmp/.chump-locks"
    cd "$tmp"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "test@ci.local" 2>/dev/null || true
    git config user.name "CI" 2>/dev/null || true

    export CHUMP_REPO="$tmp"
    export CHUMP_WORKTREE_ROOT="$tmp"
    export CHUMP_HOME="$tmp"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: similarity check blocks 2nd+ fixture gap reservation → empty
    # pillar counts → all alert assertions fail.
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    printf '%s' "$tmp"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate 2>/dev/null || true
}

# ── Test 2: balanced pillars exit 0 ──────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar)"
TMP2="$(setup_test_repo)"
trap 'rm -rf "$TMP2" 2>/dev/null || true' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-a"
    reserve_gap "${p}: balanced-b"
done

AMBIENT="$TMP2/.chump-locks/ambient.jsonl"
export AMBIENT

if AMBIENT="$AMBIENT" bash "$PBS" >/dev/null 2>&1; then
    ok "balanced pillars (2 per pillar) exit 0"
else
    fail "balanced pillars should exit 0"
fi
trap - EXIT; rm -rf "$TMP2" 2>/dev/null || true

# ── Test 3: under-fed pillar emits alert + exits non-zero ────────────────────
echo "[Test 3] Under-fed pillar alert"
TMP3="$(setup_test_repo)"

reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-only-one"
# ZERO-WASTE has 0 — also under floor

AMBIENT3="$TMP3/.chump-locks/ambient.jsonl"
: > "$AMBIENT3"

AMBIENT="$AMBIENT3" bash "$PBS" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_alert"' "$AMBIENT3" 2>/dev/null; then
    ok "pillar_balance_alert event emitted"
else
    fail "pillar_balance_alert event not found in ambient.jsonl"
fi

if grep '"kind":"pillar_balance_alert"' "$AMBIENT3" | \
   jq -e '.pillar and (.count != null) and .floor' >/dev/null 2>&1; then
    ok "pillar_balance_alert has required fields (pillar, count, floor)"
else
    fail "pillar_balance_alert missing required fields"
fi

if grep '"kind":"pillar_balance_alert"' "$AMBIENT3" | \
   jq -e '.floor == 2' >/dev/null 2>&1; then
    ok "pillar_balance_alert floor = 2"
else
    fail "pillar_balance_alert floor should be 2"
fi

rm -rf "$TMP3" 2>/dev/null || true

# ── Test 4: overweight pillar (> 50%) emits alert ────────────────────────────
echo "[Test 4] Overweight pillar alert"
TMP4="$(setup_test_repo)"

for i in 1 2 3 4 5 6; do
    reserve_gap "EFFECTIVE: overweight-$i"
done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"

AMBIENT4="$TMP4/.chump-locks/ambient.jsonl"
: > "$AMBIENT4"

AMBIENT="$AMBIENT4" bash "$PBS" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT4" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not found"
fi

if grep '"kind":"pillar_balance_overweight"' "$AMBIENT4" | \
   jq -e '.pillar and (.count != null) and (.pct != null)' >/dev/null 2>&1; then
    ok "pillar_balance_overweight has required fields (pillar, count, pct)"
else
    fail "pillar_balance_overweight missing required fields"
fi

if grep '"kind":"pillar_balance_overweight"' "$AMBIENT4" | \
   jq -e '.pct > 50' >/dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50"
else
    fail "pillar_balance_overweight pct should be > 50"
fi

rm -rf "$TMP4" 2>/dev/null || true

# ── Test 5: script ignores non-pickable gaps ─────────────────────────────────
echo "[Test 5] Script ignores non-pickable gaps"
TMP5="$(setup_test_repo)"

# Only pickable: P1 xs with real AC
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: pickable" P1 xs "real acceptance criterion"
    reserve_gap "${p}: pickable-2" P1 xs "another real criterion"
done
# Non-pickable gaps — should not be counted
reserve_gap "EFFECTIVE: p2-ignored" P2 xs "verify"
reserve_gap "EFFECTIVE: m-ignored" P1 m "verify"
reserve_gap "EFFECTIVE: todo-ac" P1 xs "TODO"
reserve_gap "CREDIBLE: todo-ac-2" P1 xs "TODO: implement this"

AMBIENT5="$TMP5/.chump-locks/ambient.jsonl"
: > "$AMBIENT5"

# With 2 pickable per pillar, should be healthy (no alerts)
if AMBIENT="$AMBIENT5" bash "$PBS" >/dev/null 2>&1; then
    ok "non-pickable gaps (P2, m-effort, TODO AC) are ignored"
else
    fail "should be healthy when only non-pickable gaps have TODO ACs"
fi

rm -rf "$TMP5" 2>/dev/null || true

# ── Test 6: healthy state produces no events ─────────────────────────────────
echo "[Test 6] Healthy state produces no events"
TMP6="$(setup_test_repo)"

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    for i in 1 2 3; do
        reserve_gap "${p}: healthy-$i" P1 xs "ac $i"
    done
done

AMBIENT6="$TMP6/.chump-locks/ambient.jsonl"
: > "$AMBIENT6"

if AMBIENT="$AMBIENT6" bash "$PBS" >/dev/null 2>&1; then
    ok "healthy state exits 0"
else
    fail "healthy state should exit 0"
fi

if [ ! -s "$AMBIENT6" ]; then
    ok "healthy state emits no events to ambient.jsonl"
else
    fail "healthy state should produce no ambient events"
fi

rm -rf "$TMP6" 2>/dev/null || true

# ── Test 7: multiple alert types in a single run ─────────────────────────────
echo "[Test 7] Multiple alert types (under-fed + overweight in same run)"
TMP7="$(setup_test_repo)"

# 10 EFFECTIVE (overweight), 1 CREDIBLE (under-fed), 0 RESILIENT/ZERO-WASTE (under-fed)
for i in $(seq 1 10); do
    reserve_gap "EFFECTIVE: multi-$i" P1 xs "verify $i"
done
reserve_gap "CREDIBLE: multi-1" P1 xs "verify"

AMBIENT7="$TMP7/.chump-locks/ambient.jsonl"
: > "$AMBIENT7"

AMBIENT="$AMBIENT7" bash "$PBS" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    ok "multiple alert types exit non-zero"
else
    fail "multiple alert types should exit non-zero"
fi

# Use ${var:-0} pattern (not grep -c || echo 0 which yields "0\n0" → arithmetic error)
under_cnt=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT7" 2>/dev/null || true)
under_cnt=${under_cnt:-0}
over_cnt=$(grep -c '"kind":"pillar_balance_overweight"' "$AMBIENT7" 2>/dev/null || true)
over_cnt=${over_cnt:-0}

if [ "$under_cnt" -gt 0 ] && [ "$over_cnt" -gt 0 ]; then
    ok "both pillar_balance_alert and pillar_balance_overweight emitted"
else
    fail "expected both alert types; under=$under_cnt over=$over_cnt"
fi

rm -rf "$TMP7" 2>/dev/null || true

# ── Test 8: ambient.jsonl events are valid JSON with ts field ─────────────────
echo "[Test 8] Alert events are valid JSON with ts field"
TMP8="$(setup_test_repo)"

reserve_gap "EFFECTIVE: json-1" P1 xs "verify"
# All other pillars have 0 — will fire under-fed alerts

AMBIENT8="$TMP8/.chump-locks/ambient.jsonl"
: > "$AMBIENT8"

AMBIENT="$AMBIENT8" bash "$PBS" >/dev/null 2>&1 || true

if [ -s "$AMBIENT8" ]; then
    all_valid=1
    while IFS= read -r line; do
        if ! printf '%s' "$line" | jq -e '.ts and .kind' >/dev/null 2>&1; then
            all_valid=0
        fi
    done < "$AMBIENT8"
    if [ "$all_valid" -eq 1 ]; then
        ok "all alert events are valid JSON with ts and kind fields"
    else
        fail "some alert events are malformed JSON or missing ts/kind"
    fi
else
    fail "no events emitted (expected under-fed alerts)"
fi

rm -rf "$TMP8" 2>/dev/null || true

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
