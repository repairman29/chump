#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# 8+ tests for scripts/ops/pillar-balance-check.sh:
#   1. Balanced registry exits 0
#   2. Single underweight pillar fires pillar_balance_alert (exit 1)
#   3. Alert event has required fields: ts, kind, pillar, count, floor
#   4. All 4 pillars underweight → 4 alert events emitted
#   5. Overweight pillar fires pillar_balance_overweight (exit 1)
#   6. Overweight event has required fields: ts, kind, pillar, count, pct, total
#   7. --json flag produces parseable output with counts + alerts keys
#   8. --dry-run flag suppresses ambient emit but still exits non-zero
#   9. CHUMP_PILLAR_BALANCE_CHECK=0 bypasses all checks (exit 0)
#  10. Empty registry (0 gaps) fires under-floor for all 4 pillars
#
# Network-free: uses CHUMP_BIN shim + CHUMP_AMBIENT_LOG pointing to tempdir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-902 pillar-balance-check tests ==="
echo

# ── Binary resolution (honors CHUMP_BIN, then CARGO_TARGET_DIR, then shared target) ──
CHUMP_BIN="${CHUMP_BIN:-}"
if [ -z "$CHUMP_BIN" ]; then
    if [ -n "${CARGO_TARGET_DIR:-}" ] && [ -x "$CARGO_TARGET_DIR/debug/chump" ]; then
        CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
    elif [ -x "$REPO_ROOT/target/debug/chump" ]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif [ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]; then
        CHUMP_BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    else
        # Try cargo metadata target dir
        META_TARGET="$(cargo metadata --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" --format-version=1 2>/dev/null \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || echo "")"
        if [ -n "$META_TARGET" ] && [ -x "$META_TARGET/debug/chump" ]; then
            CHUMP_BIN="$META_TARGET/debug/chump"
        fi
    fi
fi

if [ -z "$CHUMP_BIN" ] || [ ! -x "$CHUMP_BIN" ]; then
    echo "  [build] cargo build --bin chump ..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
    for candidate in \
        "${CARGO_TARGET_DIR:-}/debug/chump" \
        "$REPO_ROOT/target/debug/chump" \
        "/Users/jeffadkins/Projects/Chump/target/debug/chump"; do
        if [ -x "$candidate" ]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi

[ -x "${CHUMP_BIN:-}" ] || { echo "FAIL: chump binary not found"; exit 2; }
export CHUMP_BIN

echo "  Using binary: $CHUMP_BIN"
echo

# ── Fixture builder ──────────────────────────────────────────────────────────
# Spins up a fresh CHUMP_REPO in a tempdir, seeds gaps, runs the check script.

make_env() {
    local tmp="$1"
    mkdir -p "$tmp/.chump" "$tmp/docs/gaps"
    cd "$tmp"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git -C "$tmp" config user.email "test@ci.local" 2>/dev/null || true
    git -C "$tmp" config user.name "CI" 2>/dev/null || true
    export CHUMP_REPO="$tmp"
    export CHUMP_WORKTREE_ROOT="$tmp"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: prevent similarity check from blocking 2nd+ gap with similar title
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
}

seed_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --title "$title" \
        --priority "$priority" \
        --effort "$effort" \
        --acceptance-criteria "verify $title works" \
        --force --force-duplicate \
        >/dev/null 2>&1 || true
}

run_check() {
    # Run pillar-balance-check.sh with supplied args, forwarding CHUMP_BIN and
    # the per-test ambient log path.
    CHUMP_BIN="$CHUMP_BIN" \
    CHUMP_AMBIENT_LOG="$CHECK_AMB" \
    CHUMP_LOCK_DIR="$(dirname "$CHECK_AMB")" \
        bash "$SCRIPT" "$@"
}

# ── Test 1: balanced registry exits 0 ────────────────────────────────────────
echo "--- Test 1: balanced registry exits 0 ---"
T1="$(mktemp -d)"
trap 'rm -rf "$T1"' EXIT
make_env "$T1"
CHECK_AMB="$T1/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

# 2 gaps per pillar → exactly at floor, none overweight (50% of 8 = 4, no pillar hits that)
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    seed_gap "${p}: t1-gap-a"
    seed_gap "${p}: t1-gap-b"
done

if run_check >/dev/null 2>&1; then
    ok "balanced registry exits 0"
else
    fail "balanced registry should exit 0"
fi

# ── Test 2: single underweight pillar fires alert (exit 1) ───────────────────
echo
echo "--- Test 2: single underweight pillar fires pillar_balance_alert ---"
T2="$(mktemp -d)"
make_env "$T2"
CHECK_AMB="$T2/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

# 2 each for EFFECTIVE, RESILIENT, ZERO-WASTE but only 1 for CREDIBLE
for p in EFFECTIVE RESILIENT ZERO-WASTE; do
    seed_gap "${p}: t2-gap-a"
    seed_gap "${p}: t2-gap-b"
done
seed_gap "CREDIBLE: t2-only-one"

if run_check >/dev/null 2>&1; then
    fail "underweight pillar should cause exit 1"
else
    ok "underweight pillar causes exit 1"
fi

if [ -f "$CHECK_AMB" ] && grep -q '"kind":"pillar_balance_alert"' "$CHECK_AMB"; then
    ok "pillar_balance_alert event emitted"
else
    fail "pillar_balance_alert event not emitted"
fi

# ── Test 3: alert event has required schema fields ────────────────────────────
echo
echo "--- Test 3: alert event schema (ts, kind, pillar, count, floor) ---"
if [ -f "$CHECK_AMB" ]; then
    EVENT="$(grep '"kind":"pillar_balance_alert"' "$CHECK_AMB" | tail -1)"
    for field in ts kind pillar count floor; do
        if echo "$EVENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
            ok "alert event has field '$field'"
        else
            fail "alert event missing field '$field' — got: $EVENT"
        fi
    done
    # Verify field values
    if echo "$EVENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['pillar']=='CREDIBLE'" 2>/dev/null; then
        ok "alert event pillar=CREDIBLE"
    else
        fail "alert event pillar should be CREDIBLE — got: $EVENT"
    fi
    if echo "$EVENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['count']==1" 2>/dev/null; then
        ok "alert event count=1"
    else
        fail "alert event count should be 1 — got: $EVENT"
    fi
    if echo "$EVENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['floor']==2" 2>/dev/null; then
        ok "alert event floor=2"
    else
        fail "alert event floor should be 2 — got: $EVENT"
    fi
else
    fail "ambient log not created"
fi

# ── Test 4: all 4 pillars underweight → 4 alert events ───────────────────────
echo
echo "--- Test 4: all pillars underweight → 4 alerts ---"
T4="$(mktemp -d)"
make_env "$T4"
CHECK_AMB="$T4/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

# Only 1 gap per pillar (all under floor=2)
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    seed_gap "${p}: t4-solo"
done

run_check >/dev/null 2>&1 || true
ALERT_CNT="$(grep -c '"kind":"pillar_balance_alert"' "$CHECK_AMB" 2>/dev/null || echo 0)"
ALERT_CNT="${ALERT_CNT:-0}"
if [ "$ALERT_CNT" -eq 4 ]; then
    ok "4 pillar_balance_alert events emitted (one per pillar)"
else
    fail "expected 4 pillar_balance_alert events, got $ALERT_CNT"
fi

# ── Test 5: overweight pillar fires pillar_balance_overweight ─────────────────
echo
echo "--- Test 5: overweight pillar fires pillar_balance_overweight ---"
T5="$(mktemp -d)"
make_env "$T5"
CHECK_AMB="$T5/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

# 8 EFFECTIVE + 1 each of the rest = EFFECTIVE at 8/11 = 72% > 50%
for i in $(seq 1 8); do
    seed_gap "EFFECTIVE: t5-dominate-$i"
done
seed_gap "CREDIBLE: t5-credible"
seed_gap "RESILIENT: t5-resilient"
seed_gap "ZERO-WASTE: t5-zerowaste"

if run_check >/dev/null 2>&1; then
    fail "overweight pillar should cause exit 1"
else
    ok "overweight pillar causes exit 1"
fi

if [ -f "$CHECK_AMB" ] && grep -q '"kind":"pillar_balance_overweight"' "$CHECK_AMB"; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not emitted"
fi

# ── Test 6: overweight event schema ──────────────────────────────────────────
echo
echo "--- Test 6: overweight event schema (ts, kind, pillar, count, pct, total) ---"
if [ -f "$CHECK_AMB" ]; then
    OW_EVENT="$(grep '"kind":"pillar_balance_overweight"' "$CHECK_AMB" | tail -1)"
    for field in ts kind pillar count pct total; do
        if echo "$OW_EVENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
            ok "overweight event has field '$field'"
        else
            fail "overweight event missing field '$field' — got: $OW_EVENT"
        fi
    done
    if echo "$OW_EVENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['pillar']=='EFFECTIVE'" 2>/dev/null; then
        ok "overweight event pillar=EFFECTIVE"
    else
        fail "overweight event pillar should be EFFECTIVE — got: $OW_EVENT"
    fi
    if echo "$OW_EVENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['pct'] > 50" 2>/dev/null; then
        ok "overweight event pct > 50"
    else
        fail "overweight event pct should be >50 — got: $OW_EVENT"
    fi
else
    fail "ambient log not created for test 6"
fi

# ── Test 7: --json flag produces parseable output ────────────────────────────
echo
echo "--- Test 7: --json flag ---"
T7="$(mktemp -d)"
make_env "$T7"
CHECK_AMB="$T7/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    seed_gap "${p}: t7-gap-a"
    seed_gap "${p}: t7-gap-b"
done

JSON_OUT="$(run_check --json 2>/dev/null)"
for key in total_pickable counts alerts overweights floor; do
    if echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
        ok "--json output has key '$key'"
    else
        fail "--json output missing key '$key' — got: $JSON_OUT"
    fi
done
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    if echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$p' in d['counts']" 2>/dev/null; then
        ok "--json counts.$p present"
    else
        fail "--json counts.$p missing"
    fi
done

# ── Test 8: --dry-run suppresses ambient emit ─────────────────────────────────
echo
echo "--- Test 8: --dry-run suppresses ambient emit ---"
T8="$(mktemp -d)"
make_env "$T8"
CHECK_AMB="$T8/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

# 1 CREDIBLE only → alert would fire
seed_gap "CREDIBLE: t8-only"

# --dry-run should still exit non-zero (alert condition exists) but NOT write ambient
DRY_EXIT=0
run_check --dry-run >/dev/null 2>&1 || DRY_EXIT=$?
if [ "$DRY_EXIT" -ne 0 ]; then
    ok "--dry-run exits non-zero when alert condition exists"
else
    fail "--dry-run should exit non-zero when alerts exist (got exit 0)"
fi

if [ ! -f "$CHECK_AMB" ] || ! grep -q '"kind":"pillar_balance_alert"' "$CHECK_AMB" 2>/dev/null; then
    ok "--dry-run suppresses ambient emit"
else
    fail "--dry-run should NOT write to ambient log"
fi

# ── Test 9: CHUMP_PILLAR_BALANCE_CHECK=0 bypasses all checks ─────────────────
echo
echo "--- Test 9: CHUMP_PILLAR_BALANCE_CHECK=0 bypass ---"
T9="$(mktemp -d)"
make_env "$T9"
CHECK_AMB="$T9/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

# Would normally alert (only 1 CREDIBLE gap), but bypass should skip
seed_gap "CREDIBLE: t9-only"

if CHUMP_PILLAR_BALANCE_CHECK=0 CHUMP_BIN="$CHUMP_BIN" CHUMP_AMBIENT_LOG="$CHECK_AMB" \
       bash "$SCRIPT" >/dev/null 2>&1; then
    ok "CHUMP_PILLAR_BALANCE_CHECK=0 exits 0"
else
    fail "CHUMP_PILLAR_BALANCE_CHECK=0 should bypass and exit 0"
fi

# ── Test 10: empty registry fires under-floor for all 4 pillars ──────────────
echo
echo "--- Test 10: empty registry → 4 alerts ---"
T10="$(mktemp -d)"
make_env "$T10"
CHECK_AMB="$T10/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$CHECK_AMB")"

# No gaps seeded — all pillars at 0 < 2
run_check >/dev/null 2>&1 || true
EMPTY_ALERTS="$(grep -c '"kind":"pillar_balance_alert"' "$CHECK_AMB" 2>/dev/null || echo 0)"
EMPTY_ALERTS="${EMPTY_ALERTS:-0}"
if [ "$EMPTY_ALERTS" -eq 4 ]; then
    ok "empty registry → 4 pillar_balance_alert events"
else
    fail "empty registry should produce 4 alerts, got $EMPTY_ALERTS"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
