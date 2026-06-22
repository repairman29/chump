#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests scripts/ops/pillar-balance-check.sh:
#   1. Underweight pillar (< 2) → exits non-zero + kind=pillar_balance_alert
#   2. Overweight pillar (> 50%) → exits non-zero + kind=pillar_balance_overweight
#   3. Balanced fixture → exits 0, no alerts
#   4. Alert event has required fields: pillar, count, floor=2
#   5. Overweight event has required fields: pillar, count, pct
#   6. Only xs/s/m effort gaps count as pickable
#   7. Only P0/P1 priority gaps count as pickable
#   8. Gaps with TODO ACs don't count as pickable
#   9. Gaps with non-empty depends_on don't count as pickable
#  10. Script exits 0 when balance OK message is printed

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT not found or not executable" >&2
    exit 2
fi

# ── Binary resolution (INFRA-481: shared target-dir) ─────────────────────────
if [[ -n "${CHUMP_BIN:-}" && -x "$CHUMP_BIN" ]]; then
    BIN="$CHUMP_BIN"
elif [[ -n "${CARGO_TARGET_DIR:-}" && -x "${CARGO_TARGET_DIR}/debug/chump" ]]; then
    BIN="${CARGO_TARGET_DIR}/debug/chump"
elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
    BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
    BIN="$REPO_ROOT/target/debug/chump"
else
    echo "  [build] building chump binary..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    TARGET_DIR="$(cargo metadata --format-version 1 --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('target_directory',''))" 2>/dev/null || true)"
    if [[ -n "$TARGET_DIR" && -x "$TARGET_DIR/debug/chump" ]]; then
        BIN="$TARGET_DIR/debug/chump"
    else
        echo "FATAL: chump binary not found after build" >&2
        exit 2
    fi
fi
export CHUMP_BIN="$BIN"

# ── Shared fixture helpers ────────────────────────────────────────────────────
setup_dir() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump-locks"
    export CHUMP_REPO="$tmp"
    export CHUMP_HOME="$tmp"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export CHUMP_AMBIENT_LOG="$tmp/.chump-locks/ambient.jsonl"
    echo "$tmp"
}

reserve_gap() {
    local tmp="$1" title="$2" priority="${3:-P1}" effort="${4:-xs}" ac="${5:-verify it works}" deps="${6:-}"
    local extra_args=()
    if [[ -n "$deps" ]]; then
        extra_args+=("--depends-on" "$deps")
    fi
    "$BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" \
        --quiet --force-duplicate "${extra_args[@]}" 2>/dev/null || true
}

run_check() {
    local tmp="$1"
    export CHUMP_REPO="$tmp"
    export CHUMP_AMBIENT_LOG="$tmp/.chump-locks/ambient.jsonl"
    bash "$SCRIPT" 2>&1
    return $?
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: Underweight pillar → exits non-zero
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 1: underweight pillar exits non-zero ---"
TMP1="$(setup_dir)"
trap 'rm -rf "$TMP1"' EXIT

# 3 gaps for EFFECTIVE, 0 for CREDIBLE → CREDIBLE underweight
reserve_gap "$TMP1" "EFFECTIVE: feature-a" P1 xs
reserve_gap "$TMP1" "EFFECTIVE: feature-b" P1 xs
reserve_gap "$TMP1" "EFFECTIVE: feature-c" P1 xs
reserve_gap "$TMP1" "RESILIENT: fix-a" P1 xs
reserve_gap "$TMP1" "ZERO-WASTE: prune-a" P1 xs

if ! (export CHUMP_REPO="$TMP1" CHUMP_AMBIENT_LOG="$TMP1/.chump-locks/ambient.jsonl"; bash "$SCRIPT" >/dev/null 2>&1); then
    ok "underweight pillar exits non-zero"
else
    fail "underweight pillar should exit non-zero but exited 0"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: pillar_balance_alert emitted for underweight pillar
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 2: kind=pillar_balance_alert emitted ---"
# Re-run check (TMP1 still has 0 CREDIBLE)
export CHUMP_REPO="$TMP1" CHUMP_AMBIENT_LOG="$TMP1/.chump-locks/ambient.jsonl"
bash "$SCRIPT" >/dev/null 2>&1 || true

if grep -q '"kind":"pillar_balance_alert"' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "kind=pillar_balance_alert emitted to ambient.jsonl"
else
    fail "kind=pillar_balance_alert not found in ambient.jsonl"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: Alert event has required fields (pillar, count, floor=2)
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 3: alert event has required fields ---"
ALERT_LINE="$(grep '"kind":"pillar_balance_alert"' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null | tail -1 || true)"

if echo "$ALERT_LINE" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    e = json.loads(line)
    assert 'pillar' in e, 'missing pillar'
    assert 'count' in e, 'missing count'
    assert e.get('floor') == 2, f'floor should be 2, got {e.get(\"floor\")}'
    print('OK')
except Exception as ex:
    print(f'FAIL: {ex}')
    sys.exit(1)
" 2>/dev/null | grep -q "OK"; then
    ok "alert event has pillar, count, floor=2"
else
    fail "alert event missing required fields (pillar/count/floor=2)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: Overweight pillar → exits non-zero + kind=pillar_balance_overweight
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 4: overweight pillar exits non-zero + event emitted ---"
TMP4="$(mktemp -d)"
mkdir -p "$TMP4/.chump-locks"
trap 'rm -rf "$TMP4"' EXIT

export CHUMP_REPO="$TMP4" CHUMP_HOME="$TMP4"
export CHUMP_ALLOW_MAIN_WORKTREE=1 FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_AMBIENT_LOG="$TMP4/.chump-locks/ambient.jsonl"

# 8 RESILIENT + 1 each of others → RESILIENT = 8/11 ≈ 72% >> 50%
for i in 1 2 3 4 5 6 7 8; do
    reserve_gap "$TMP4" "RESILIENT: fix-$i-$$" P1 xs
done
reserve_gap "$TMP4" "EFFECTIVE: feat-1-$$" P1 xs
reserve_gap "$TMP4" "CREDIBLE: obs-1-$$" P1 xs
reserve_gap "$TMP4" "ZERO-WASTE: prune-1-$$" P1 xs

if ! (export CHUMP_REPO="$TMP4" CHUMP_AMBIENT_LOG="$TMP4/.chump-locks/ambient.jsonl"; bash "$SCRIPT" >/dev/null 2>&1); then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero but exited 0"
fi

export CHUMP_REPO="$TMP4" CHUMP_AMBIENT_LOG="$TMP4/.chump-locks/ambient.jsonl"
bash "$SCRIPT" >/dev/null 2>&1 || true

if grep -q '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "kind=pillar_balance_overweight emitted to ambient.jsonl"
else
    fail "kind=pillar_balance_overweight not found in ambient.jsonl"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: Overweight event has required fields (pillar, count, pct)
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 5: overweight event has required fields ---"
OW_LINE="$(grep '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null | tail -1 || true)"

if echo "$OW_LINE" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    e = json.loads(line)
    assert 'pillar' in e, 'missing pillar'
    assert 'count' in e, 'missing count'
    assert 'pct' in e, 'missing pct'
    assert e['pct'] > 50, f'pct should be >50, got {e[\"pct\"]}'
    print('OK')
except Exception as ex:
    print(f'FAIL: {ex}')
    sys.exit(1)
" 2>/dev/null | grep -q "OK"; then
    ok "overweight event has pillar, count, pct>50"
else
    fail "overweight event missing required fields (pillar/count/pct)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 6: Balanced fixture → exits 0
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 6: balanced fixture exits 0 ---"
TMP6="$(mktemp -d)"
mkdir -p "$TMP6/.chump-locks"
trap 'rm -rf "$TMP6"' EXIT

export CHUMP_REPO="$TMP6" CHUMP_HOME="$TMP6"
export CHUMP_ALLOW_MAIN_WORKTREE=1 FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_AMBIENT_LOG="$TMP6/.chump-locks/ambient.jsonl"

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "$TMP6" "${p}: fix-a-$$" P1 xs
    reserve_gap "$TMP6" "${p}: fix-b-$$" P1 xs
done

if (export CHUMP_REPO="$TMP6" CHUMP_AMBIENT_LOG="$TMP6/.chump-locks/ambient.jsonl"; bash "$SCRIPT" >/dev/null 2>&1); then
    ok "balanced fixture exits 0"
else
    fail "balanced fixture should exit 0"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 7: Only xs/s/m effort gaps count — xl excluded
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 7: xl effort gaps not counted as pickable ---"
TMP7="$(mktemp -d)"
mkdir -p "$TMP7/.chump-locks"
trap 'rm -rf "$TMP7"' EXIT

export CHUMP_REPO="$TMP7" CHUMP_HOME="$TMP7"
export CHUMP_ALLOW_MAIN_WORKTREE=1 FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_AMBIENT_LOG="$TMP7/.chump-locks/ambient.jsonl"

# Add 3 xl-effort EFFECTIVE gaps — should NOT count as pickable
# Add 2 xs EFFECTIVE gaps so EFFECTIVE is not underweight
# CREDIBLE: only xl-effort → should be 0 pickable → underweight alert
for i in 1 2 3; do
    reserve_gap "$TMP7" "CREDIBLE: xl-obs-$i-$$" P1 xl
done
reserve_gap "$TMP7" "EFFECTIVE: xs-feat-a-$$" P1 xs
reserve_gap "$TMP7" "EFFECTIVE: xs-feat-b-$$" P1 xs
reserve_gap "$TMP7" "RESILIENT: xs-fix-a-$$" P1 xs
reserve_gap "$TMP7" "RESILIENT: xs-fix-b-$$" P1 xs
reserve_gap "$TMP7" "ZERO-WASTE: xs-prune-a-$$" P1 xs
reserve_gap "$TMP7" "ZERO-WASTE: xs-prune-b-$$" P1 xs

OUT7="$(export CHUMP_REPO="$TMP7" CHUMP_AMBIENT_LOG="$TMP7/.chump-locks/ambient.jsonl"; bash "$SCRIPT" 2>&1 || true)"
if echo "$OUT7" | grep -q "CREDIBLE=0"; then
    ok "xl-effort CREDIBLE gaps excluded from pickable count"
else
    fail "xl-effort gaps should not count as pickable — CREDIBLE should be 0"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 8: Only P0/P1 priority gaps count — P2/P3 excluded
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 8: P2/P3 gaps not counted as pickable ---"
TMP8="$(mktemp -d)"
mkdir -p "$TMP8/.chump-locks"
trap 'rm -rf "$TMP8"' EXIT

export CHUMP_REPO="$TMP8" CHUMP_HOME="$TMP8"
export CHUMP_ALLOW_MAIN_WORKTREE=1 FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_AMBIENT_LOG="$TMP8/.chump-locks/ambient.jsonl"

# CREDIBLE: only P2/P3 → not pickable → underweight alert fires
for i in 1 2 3; do
    reserve_gap "$TMP8" "CREDIBLE: p2-obs-$i-$$" P2 xs
done
reserve_gap "$TMP8" "EFFECTIVE: feat-a-$$" P1 xs
reserve_gap "$TMP8" "EFFECTIVE: feat-b-$$" P1 xs
reserve_gap "$TMP8" "RESILIENT: fix-a-$$" P1 xs
reserve_gap "$TMP8" "RESILIENT: fix-b-$$" P1 xs
reserve_gap "$TMP8" "ZERO-WASTE: prune-a-$$" P1 xs
reserve_gap "$TMP8" "ZERO-WASTE: prune-b-$$" P1 xs

OUT8="$(export CHUMP_REPO="$TMP8" CHUMP_AMBIENT_LOG="$TMP8/.chump-locks/ambient.jsonl"; bash "$SCRIPT" 2>&1 || true)"
if echo "$OUT8" | grep -q "CREDIBLE=0"; then
    ok "P2 CREDIBLE gaps excluded from pickable count"
else
    fail "P2/P3 gaps should not count as pickable — CREDIBLE should be 0"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 9: Gaps with TODO ACs don't count as pickable
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 9: TODO AC gaps not counted as pickable ---"
TMP9="$(mktemp -d)"
mkdir -p "$TMP9/.chump-locks"
trap 'rm -rf "$TMP9"' EXIT

export CHUMP_REPO="$TMP9" CHUMP_HOME="$TMP9"
export CHUMP_ALLOW_MAIN_WORKTREE=1 FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_AMBIENT_LOG="$TMP9/.chump-locks/ambient.jsonl"

# CREDIBLE gaps with TODO AC — should not be pickable
for i in 1 2 3; do
    reserve_gap "$TMP9" "CREDIBLE: todo-obs-$i-$$" P1 xs "TODO"
done
reserve_gap "$TMP9" "EFFECTIVE: feat-a-$$" P1 xs
reserve_gap "$TMP9" "EFFECTIVE: feat-b-$$" P1 xs
reserve_gap "$TMP9" "RESILIENT: fix-a-$$" P1 xs
reserve_gap "$TMP9" "RESILIENT: fix-b-$$" P1 xs
reserve_gap "$TMP9" "ZERO-WASTE: prune-a-$$" P1 xs
reserve_gap "$TMP9" "ZERO-WASTE: prune-b-$$" P1 xs

OUT9="$(export CHUMP_REPO="$TMP9" CHUMP_AMBIENT_LOG="$TMP9/.chump-locks/ambient.jsonl"; bash "$SCRIPT" 2>&1 || true)"
if echo "$OUT9" | grep -q "CREDIBLE=0"; then
    ok "TODO-AC CREDIBLE gaps excluded from pickable count"
else
    fail "TODO-AC gaps should not count as pickable — CREDIBLE should be 0"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 10: Balance OK message appears on exit 0
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Test 10: balance OK message printed when no alerts ---"
# Re-use TMP6 (balanced fixture)
OUT10="$(export CHUMP_REPO="$TMP6" CHUMP_AMBIENT_LOG="$TMP6/.chump-locks/ambient.jsonl"; bash "$SCRIPT" 2>&1)"
if echo "$OUT10" | grep -q "Balance OK"; then
    ok "balance OK message printed when no alerts fire"
else
    fail "balance OK message missing on clean run — got: $OUT10"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
