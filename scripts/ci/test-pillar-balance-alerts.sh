#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests scripts/ops/pillar-balance-check.sh:
#   1. Script exists and is executable
#   2. Balanced fixture exits 0, no alert events emitted
#   3. Under-floor pillar emits pillar_balance_alert with required fields
#   4. pillar_balance_alert JSON has pillar, count, floor fields
#   5. Overweight pillar emits pillar_balance_overweight with required fields
#   6. pillar_balance_overweight JSON has pillar, count, pct fields
#   7. Multiple under-floor pillars → multiple alert events
#   8. --dry-run does NOT write to ambient.jsonl
#   9. Total=0 → all four pillars under floor → four alerts
#  10. Exit 0 when no alerts fire; exit 1 when any alert fires

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts test ==="
echo

# ── Test 1: Script exists and is executable ───────────────────────────────────
if [ -x "$SCRIPT" ]; then
    ok "pillar-balance-check.sh is executable"
else
    fail "pillar-balance-check.sh missing or not executable at $SCRIPT"
    echo "FATAL: script missing — aborting remaining tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# ── Resolve chump binary (INFRA-481: honor cargo target_dir; fix 5) ──────────
if [ -z "${CHUMP_BIN:-}" ]; then
    _td=""
    if _td_raw="$(cargo metadata --no-deps --format-version 1 \
            --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null)"; then
        _td="$(printf '%s' "$_td_raw" | \
            python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' \
            2>/dev/null || true)"
    fi
    if [ -x "${_td:-}/debug/chump" ]; then
        CHUMP_BIN="${_td}/debug/chump"
    elif [ -x "$REPO_ROOT/target/debug/chump" ]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    else
        echo "  [build] cargo build --bin chump..."
        cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
        if [ -n "${_td:-}" ] && [ -x "${_td}/debug/chump" ]; then
            CHUMP_BIN="${_td}/debug/chump"
        elif [ -x "$REPO_ROOT/target/debug/chump" ]; then
            CHUMP_BIN="$REPO_ROOT/target/debug/chump"
        else
            fail "chump binary not found after build — skipping functional tests"
            echo
            echo "=== Results: $PASS passed, $FAIL failed ==="
            exit 1
        fi
    fi
fi

# Export CHUMP_BIN so pillar-balance-check.sh uses the fixture binary (fix 4)
export CHUMP_BIN

echo "Using binary: $CHUMP_BIN"
echo

# ── Helper: create isolated fixture ──────────────────────────────────────────
make_fixture() {
    local _tmp
    _tmp="$(mktemp -d)"
    mkdir -p "$_tmp/.chump" "$_tmp/docs/gaps" "$_tmp/.chump-locks"
    cd "$_tmp"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git -C "$_tmp" config user.email "test@ci.local" 2>/dev/null || true
    git -C "$_tmp" config user.name "CI" 2>/dev/null || true
    printf '%s' "$_tmp"
}

reserve_gap() {
    local _title="$1" _priority="${2:-P1}" _effort="${3:-xs}"
    "$CHUMP_BIN" gap reserve --domain INFRA \
        --priority "$_priority" --effort "$_effort" \
        --title "$_title" \
        --acceptance-criteria "verify $_title works" \
        --force-duplicate --quiet 2>/dev/null || true
}

run_check() {
    bash "$SCRIPT" "$@" 2>&1
    return $?
}

# ── Test 2: Balanced fixture exits 0, no alerts ───────────────────────────────
echo "[test 2: balanced fixture]"
TMP2="$(make_fixture)"
AMBIENT2="$TMP2/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP2"
export CHUMP_HOME="$TMP2"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1   # fix 6: bypass INFRA-1149 similarity block
export CHUMP_BINARY_STALENESS_CHECK=0

# 2 gaps per pillar → each at floor (2), none overweight (2/8 = 25%)
for _p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${_p}: fixture-a"
    reserve_gap "${_p}: fixture-b"
done

if CHUMP_AMBIENT_LOG="$AMBIENT2" run_check --quiet > /dev/null 2>&1; then
    ok "balanced fixture exits 0"
else
    fail "balanced fixture should exit 0"
fi

if [ ! -f "$AMBIENT2" ] || ! grep -q "pillar_balance_alert\|pillar_balance_overweight" "$AMBIENT2" 2>/dev/null; then
    ok "balanced fixture emits no alert events"
else
    fail "balanced fixture should not emit alerts — found: $(cat "$AMBIENT2" 2>/dev/null)"
fi

rm -rf "$TMP2"

# ── Test 3 & 4: Under-floor pillar → pillar_balance_alert with correct fields ──
echo
echo "[test 3-4: under-floor → pillar_balance_alert]"
TMP3="$(make_fixture)"
AMBIENT3="$TMP3/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP3"
export CHUMP_HOME="$TMP3"

# 3 EFFECTIVE, 0 CREDIBLE — CREDIBLE should alert (count=0 < floor=2)
reserve_gap "EFFECTIVE: gap-a"
reserve_gap "EFFECTIVE: gap-b"
reserve_gap "EFFECTIVE: gap-c"

if ! CHUMP_AMBIENT_LOG="$AMBIENT3" run_check > /dev/null 2>&1; then
    ok "under-floor pillar exits non-zero"
else
    fail "under-floor pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_alert"' "$AMBIENT3" 2>/dev/null; then
    ok "under-floor emits pillar_balance_alert event"
else
    fail "under-floor should emit pillar_balance_alert — ambient: $(cat "$AMBIENT3" 2>/dev/null)"
fi

# Test 4: required JSON fields in alert event
_alert_ev="$(grep '"kind":"pillar_balance_alert"' "$AMBIENT3" 2>/dev/null | head -1)"
_missing_fields=""
for _f in ts kind pillar count floor; do
    if ! printf '%s' "${_alert_ev:-}" | python3 -c \
        "import sys,json; d=json.loads(sys.stdin.read()); assert '$_f' in d" 2>/dev/null; then
        _missing_fields="$_missing_fields $_f"
    fi
done
if [ -z "$_missing_fields" ]; then
    ok "pillar_balance_alert has all required fields (ts,kind,pillar,count,floor)"
else
    fail "pillar_balance_alert missing fields:$_missing_fields — event: ${_alert_ev:-<none>}"
fi

# Verify 'floor' field value matches default (2)
_floor_val="$(printf '%s' "${_alert_ev:-}" | python3 -c \
    "import sys,json; print(json.loads(sys.stdin.read()).get('floor','MISSING'))" 2>/dev/null || echo "MISSING")"
if [ "$_floor_val" = "2" ]; then
    ok "pillar_balance_alert floor field = 2"
else
    fail "pillar_balance_alert floor should be 2, got: $_floor_val"
fi

rm -rf "$TMP3"

# ── Test 5 & 6: Overweight pillar → pillar_balance_overweight with correct fields
echo
echo "[test 5-6: overweight → pillar_balance_overweight]"
TMP5="$(make_fixture)"
AMBIENT5="$TMP5/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP5"
export CHUMP_HOME="$TMP5"

# 8 RESILIENT, 2 EFFECTIVE (floor met but RESILIENT = 80% > 50% threshold)
for _i in $(seq 1 8); do
    reserve_gap "RESILIENT: gap-$_i"
done
reserve_gap "EFFECTIVE: gap-1"
reserve_gap "EFFECTIVE: gap-2"

if ! CHUMP_AMBIENT_LOG="$AMBIENT5" run_check > /dev/null 2>&1; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT5" 2>/dev/null; then
    ok "overweight emits pillar_balance_overweight event"
else
    fail "overweight should emit pillar_balance_overweight — ambient: $(cat "$AMBIENT5" 2>/dev/null)"
fi

# Test 6: required JSON fields in overweight event
_over_ev="$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT5" 2>/dev/null | head -1)"
_missing_fields=""
for _f in ts kind pillar count pct; do
    if ! printf '%s' "${_over_ev:-}" | python3 -c \
        "import sys,json; d=json.loads(sys.stdin.read()); assert '$_f' in d" 2>/dev/null; then
        _missing_fields="$_missing_fields $_f"
    fi
done
if [ -z "$_missing_fields" ]; then
    ok "pillar_balance_overweight has all required fields (ts,kind,pillar,count,pct)"
else
    fail "pillar_balance_overweight missing fields:$_missing_fields — event: ${_over_ev:-<none>}"
fi

# Verify pct > 50
_pct_val="$(printf '%s' "${_over_ev:-}" | python3 -c \
    "import sys,json; print(json.loads(sys.stdin.read()).get('pct', 0))" 2>/dev/null || echo "0")"
if [ "${_pct_val:-0}" -gt 50 ] 2>/dev/null; then
    ok "pillar_balance_overweight pct=${_pct_val} > 50"
else
    fail "pillar_balance_overweight pct should be >50, got: ${_pct_val:-0}"
fi

rm -rf "$TMP5"

# ── Test 7: Multiple under-floor → multiple alert events ─────────────────────
echo
echo "[test 7: multiple under-floor pillars → multiple alerts]"
TMP7="$(make_fixture)"
AMBIENT7="$TMP7/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP7"
export CHUMP_HOME="$TMP7"

# Only EFFECTIVE has gaps; CREDIBLE, RESILIENT, ZERO-WASTE all at 0 → 3 alerts
reserve_gap "EFFECTIVE: only-a"
reserve_gap "EFFECTIVE: only-b"
reserve_gap "EFFECTIVE: only-c"

CHUMP_AMBIENT_LOG="$AMBIENT7" run_check > /dev/null 2>&1 || true

_alert_count=0
if [ -f "$AMBIENT7" ]; then
    _alert_count="$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT7" 2>/dev/null || echo 0)"
fi
_alert_count="${_alert_count:-0}"
if [ "$_alert_count" -ge 3 ]; then
    ok "multiple under-floor → $((${_alert_count})) pillar_balance_alert events (≥3)"
else
    fail "expected ≥3 pillar_balance_alert events, got ${_alert_count:-0}"
fi

rm -rf "$TMP7"

# ── Test 8: --dry-run does NOT write to ambient.jsonl ─────────────────────────
echo
echo "[test 8: --dry-run does not write ambient.jsonl]"
TMP8="$(make_fixture)"
AMBIENT8="$TMP8/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP8"
export CHUMP_HOME="$TMP8"

# 0 gaps → all pillars under floor
CHUMP_AMBIENT_LOG="$AMBIENT8" run_check --dry-run > /dev/null 2>&1 || true

if [ ! -f "$AMBIENT8" ] || ! grep -q '"kind":"pillar_balance' "$AMBIENT8" 2>/dev/null; then
    ok "--dry-run: no alert events written to ambient.jsonl"
else
    fail "--dry-run should not write to ambient.jsonl"
fi

rm -rf "$TMP8"

# ── Test 9: Total=0 (no gaps) → all 4 pillars under floor → 4 alerts ─────────
echo
echo "[test 9: empty gap db → 4 alerts]"
TMP9="$(make_fixture)"
AMBIENT9="$TMP9/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP9"
export CHUMP_HOME="$TMP9"

# No gaps at all
CHUMP_AMBIENT_LOG="$AMBIENT9" run_check > /dev/null 2>&1 || true

_empty_alerts=0
if [ -f "$AMBIENT9" ]; then
    _empty_alerts="$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT9" 2>/dev/null || echo 0)"
fi
_empty_alerts="${_empty_alerts:-0}"
if [ "$_empty_alerts" -eq 4 ]; then
    ok "empty db → exactly 4 pillar_balance_alert events (one per pillar)"
else
    fail "empty db should yield 4 pillar_balance_alert events, got ${_empty_alerts:-0}"
fi

rm -rf "$TMP9"

# ── Test 10: Exit code contract ───────────────────────────────────────────────
echo
echo "[test 10: exit code contract]"
TMP10="$(make_fixture)"
AMBIENT10="$TMP10/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP10"
export CHUMP_HOME="$TMP10"

# Exactly at floor (2 per pillar) → should exit 0
for _p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${_p}: floor-a"
    reserve_gap "${_p}: floor-b"
done

if CHUMP_AMBIENT_LOG="$AMBIENT10" run_check --quiet > /dev/null 2>&1; then
    ok "exactly-at-floor exits 0 (no alert)"
else
    fail "exactly-at-floor should exit 0"
fi

# Drop CREDIBLE to 1 → exit 1
TMP10b="$(make_fixture)"
AMBIENT10b="$TMP10b/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP10b"
export CHUMP_HOME="$TMP10b"
for _p in EFFECTIVE RESILIENT ZERO-WASTE; do
    reserve_gap "${_p}: floor-a"
    reserve_gap "${_p}: floor-b"
done
reserve_gap "CREDIBLE: only-one"

if ! CHUMP_AMBIENT_LOG="$AMBIENT10b" run_check --quiet > /dev/null 2>&1; then
    ok "one-under-floor exits 1 (alert fired)"
else
    fail "one-under-floor should exit 1"
fi

rm -rf "$TMP10" "$TMP10b"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
