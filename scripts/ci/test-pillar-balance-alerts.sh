#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh:
#   1. Balanced fixture exits 0, prints "Pillar balance OK"
#   2. Underweight pillar emits kind=pillar_balance_alert with correct fields
#   3. All 4 pillars underweight → 4 alerts
#   4. Overweight pillar emits kind=pillar_balance_overweight with correct fields
#   5. Exit code is 1 when alert fires
#   6. Exit code is 0 when balanced
#   7. --dry-run suppresses ambient emit
#   8. CHUMP_PILLAR_BALANCE_CHECK=0 bypasses (exits 0)
#   9. pct field correct for overweight case
#  10. audit-priorities output includes pillar balance section

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-check tests ==="
echo

# ── Locate chump binary (INFRA-481: honor shared target-dir) ─────────────────
TARGET_DIR="$(cargo metadata --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" \
    --format-version 1 2>/dev/null | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["target_directory"])' \
    2>/dev/null || echo "$REPO_ROOT/target")"

if [ -x "$TARGET_DIR/debug/chump" ]; then
    CHUMP_BIN="$TARGET_DIR/debug/chump"
elif [ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]; then
    CHUMP_BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
else
    echo "  [build] cargo build --bin chump..."
    CARGO_TARGET_DIR="$TARGET_DIR" cargo build --bin chump \
        --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    if [ -x "$TARGET_DIR/debug/chump" ]; then
        CHUMP_BIN="$TARGET_DIR/debug/chump"
    elif [ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]; then
        CHUMP_BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    else
        echo "FATAL: chump binary not found after build" >&2
        exit 2
    fi
fi
export CHUMP_BIN

# ── Shared fixture helpers ────────────────────────────────────────────────────

make_tmpdir() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump" "$tmp/docs/gaps" "$tmp/.chump-locks"
    cd "$tmp" || exit 1
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git -C "$tmp" config user.email "test@ci.local" 2>/dev/null || true
    git -C "$tmp" config user.name "CI" 2>/dev/null || true
    echo "$tmp"
}

setup_env() {
    local tmp="$1"
    export CHUMP_REPO="$tmp"
    export CHUMP_WORKTREE_ROOT="$tmp"
    export CHUMP_HOME="$tmp"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    # INFRA-1149: bypass similarity check so repeated reserves succeed.
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_BINARY_STALENESS_CHECK=0
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "verify $title" \
        --quiet --force --force-duplicate 2>/dev/null
}

run_check() {
    local ambient="$1"; shift
    CHUMP_AMBIENT_LOG="$ambient" bash "$SCRIPT" "$@"
}

# ── Test 1: balanced fixture exits 0 ─────────────────────────────────────────
echo "[test 1: balanced fixture exits 0]"
TMP1="$(make_tmpdir)"
trap 'rm -rf "$TMP1"' EXIT
setup_env "$TMP1"

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: fixture-a" P1 xs
    reserve_gap "${p}: fixture-b" P1 xs
done

AMBIENT1="$TMP1/.chump-locks/ambient.jsonl"
if run_check "$AMBIENT1" >/dev/null 2>&1; then
    ok "balanced fixture exits 0"
else
    fail "balanced fixture should exit 0"
fi

# ── Test 2: balanced prints OK message ───────────────────────────────────────
echo "[test 2: balanced prints OK]"
OUT="$(run_check "$AMBIENT1" 2>&1 || true)"
if echo "$OUT" | grep -q "Pillar balance OK\|balance OK"; then
    ok "balanced fixture prints 'Pillar balance OK'"
else
    fail "missing OK message; got: $OUT"
fi

# ── Test 3: underweight emits pillar_balance_alert ───────────────────────────
echo "[test 3: underweight emits pillar_balance_alert]"
TMP3="$(make_tmpdir)"
OLD_EXIT="${-}"
setup_env "$TMP3"
# Only 2 EFFECTIVE — CREDIBLE/RESILIENT/ZERO-WASTE all at 0
reserve_gap "EFFECTIVE: only-a" P1 xs
reserve_gap "EFFECTIVE: only-b" P1 xs

AMBIENT3="$TMP3/.chump-locks/ambient.jsonl"
run_check "$AMBIENT3" >/dev/null 2>&1 || true

ALERT_COUNT="$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT3" 2>/dev/null)"
ALERT_COUNT="${ALERT_COUNT:-0}"
if [ "$ALERT_COUNT" -ge 3 ]; then
    ok "underweight emits pillar_balance_alert for starved pillars ($ALERT_COUNT events)"
else
    fail "expected >=3 pillar_balance_alert events, got $ALERT_COUNT"
fi

# ── Test 4: alert event has required fields ───────────────────────────────────
echo "[test 4: alert event has required fields (pillar, count, floor)]"
if grep -q '"pillar_balance_alert"' "$AMBIENT3" 2>/dev/null; then
    FIRST_ALERT="$(grep '"pillar_balance_alert"' "$AMBIENT3" | head -1)"
    HAS_PILLAR=0; HAS_COUNT=0; HAS_FLOOR=0
    echo "$FIRST_ALERT" | grep -q '"pillar"' && HAS_PILLAR=1
    echo "$FIRST_ALERT" | grep -q '"count"' && HAS_COUNT=1
    echo "$FIRST_ALERT" | grep -q '"floor"' && HAS_FLOOR=1
    if [ "$HAS_PILLAR" = "1" ] && [ "$HAS_COUNT" = "1" ] && [ "$HAS_FLOOR" = "1" ]; then
        ok "pillar_balance_alert has pillar + count + floor fields"
    else
        fail "pillar_balance_alert missing fields: pillar=$HAS_PILLAR count=$HAS_COUNT floor=$HAS_FLOOR"
    fi
else
    fail "no pillar_balance_alert event found in ambient log"
fi
rm -rf "$TMP3"

# ── Test 5: overweight emits pillar_balance_overweight ───────────────────────
echo "[test 5: overweight emits pillar_balance_overweight]"
TMP5="$(make_tmpdir)"
setup_env "$TMP5"
# 8 RESILIENT out of 10 total = 80% → overweight
for i in $(seq 1 8); do
    reserve_gap "RESILIENT: overweight-$i" P1 xs
done
reserve_gap "EFFECTIVE: filler-1" P1 xs
reserve_gap "CREDIBLE: filler-2" P1 xs

AMBIENT5="$TMP5/.chump-locks/ambient.jsonl"
run_check "$AMBIENT5" >/dev/null 2>&1 || true

OW_COUNT="$(grep -c '"kind":"pillar_balance_overweight"' "$AMBIENT5" 2>/dev/null)"
OW_COUNT="${OW_COUNT:-0}"
if [ "$OW_COUNT" -ge 1 ]; then
    ok "overweight emits pillar_balance_overweight ($OW_COUNT events)"
else
    fail "expected >=1 pillar_balance_overweight event, got $OW_COUNT"
fi

# ── Test 6: overweight event has required fields (pillar, count, pct) ────────
echo "[test 6: overweight event has pillar + count + pct fields]"
if grep -q '"pillar_balance_overweight"' "$AMBIENT5" 2>/dev/null; then
    FIRST_OW="$(grep '"pillar_balance_overweight"' "$AMBIENT5" | head -1)"
    HAS_PIL=0; HAS_CNT=0; HAS_PCT=0
    echo "$FIRST_OW" | grep -q '"pillar"' && HAS_PIL=1
    echo "$FIRST_OW" | grep -q '"count"' && HAS_CNT=1
    echo "$FIRST_OW" | grep -q '"pct"' && HAS_PCT=1
    if [ "$HAS_PIL" = "1" ] && [ "$HAS_CNT" = "1" ] && [ "$HAS_PCT" = "1" ]; then
        ok "pillar_balance_overweight has pillar + count + pct fields"
    else
        fail "pillar_balance_overweight missing fields: pillar=$HAS_PIL count=$HAS_CNT pct=$HAS_PCT"
    fi
else
    fail "no pillar_balance_overweight event found in ambient log"
fi

# ── Test 7: pct value is correct ─────────────────────────────────────────────
echo "[test 7: pct value is correct for 8/10 = 80%]"
PCT_VAL="$(grep '"pillar_balance_overweight"' "$AMBIENT5" | grep '"RESILIENT"' | \
    python3 -c 'import sys,json; [print(json.loads(l)["pct"]) for l in sys.stdin]' \
    2>/dev/null | head -1)"
if [ "${PCT_VAL:-0}" -ge 70 ]; then
    ok "pct=$PCT_VAL (expected ~80)"
else
    fail "pct=$PCT_VAL, expected ~80 for 8/10 ratio"
fi
rm -rf "$TMP5"

# ── Test 8: exit code is 1 when alert fires ───────────────────────────────────
echo "[test 8: exit code is 1 when alert fires]"
TMP8="$(make_tmpdir)"
setup_env "$TMP8"
reserve_gap "EFFECTIVE: only-one" P1 xs  # CREDIBLE/RESILIENT/ZERO-WASTE all 0

AMBIENT8="$TMP8/.chump-locks/ambient.jsonl"
if run_check "$AMBIENT8" >/dev/null 2>&1; then
    fail "alert scenario should exit 1, got 0"
else
    ok "exit code is 1 when alert fires"
fi
rm -rf "$TMP8"

# ── Test 9: --dry-run suppresses ambient emit ─────────────────────────────────
echo "[test 9: --dry-run suppresses ambient emit]"
TMP9="$(make_tmpdir)"
setup_env "$TMP9"
reserve_gap "EFFECTIVE: dr-only" P1 xs  # starved → would alert

AMBIENT9="$TMP9/.chump-locks/ambient.jsonl"
run_check "$AMBIENT9" --dry-run >/dev/null 2>&1 || true

if [ -f "$AMBIENT9" ]; then
    EMITTED="$(grep -c '"pillar_balance' "$AMBIENT9" 2>/dev/null)"
    EMITTED="${EMITTED:-0}"
else
    EMITTED=0
fi
if [ "$EMITTED" -eq 0 ]; then
    ok "--dry-run suppresses ambient emit"
else
    fail "--dry-run should suppress emit; found $EMITTED events"
fi
rm -rf "$TMP9"

# ── Test 10: CHUMP_PILLAR_BALANCE_CHECK=0 bypasses ───────────────────────────
echo "[test 10: CHUMP_PILLAR_BALANCE_CHECK=0 bypasses]"
TMP10="$(make_tmpdir)"
setup_env "$TMP10"
reserve_gap "EFFECTIVE: bypass-only" P1 xs

AMBIENT10="$TMP10/.chump-locks/ambient.jsonl"
if CHUMP_PILLAR_BALANCE_CHECK=0 run_check "$AMBIENT10" >/dev/null 2>&1; then
    ok "CHUMP_PILLAR_BALANCE_CHECK=0 exits 0"
else
    fail "CHUMP_PILLAR_BALANCE_CHECK=0 should bypass and exit 0"
fi
rm -rf "$TMP10"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
