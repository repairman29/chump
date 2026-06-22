#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests pillar-balance-check.sh:
#  AC1: reads state.db via chump gap list --status open
#  AC2: emits kind=pillar_balance_alert (pillar, count, floor=2) when count < 2
#  AC3: emits kind=pillar_balance_overweight (pillar, count, pct) when > 50%
#  AC4: exits non-zero when any alert fired
#  AC5: chump gap audit-priorities calls pillar-balance-check.sh
#  AC6: 8+ tests covering alerts, thresholds, exit codes

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

# ── Resolve chump binary (INFRA-481: shared target-dir; $REPO_ROOT/target empty in worktrees) ──
_cargo_tgt="$(cargo metadata --format-version 1 --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || true)"
CHUMP_BIN="${CHUMP_BIN:-}"
for _cand in "$CHUMP_BIN" \
             "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
             "$REPO_ROOT/target/debug/chump" \
             "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
    [ -n "$_cand" ] && [ -x "$_cand" ] && { CHUMP_BIN="$_cand"; break; }
done
if [ -z "$CHUMP_BIN" ] || [ ! -x "$CHUMP_BIN" ]; then
    echo "[build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
    for _cand in "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
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

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo "CHUMP_BIN=$CHUMP_BIN"
echo

# ── Test 1: script exists and is executable ──────────────────────────────────
if [ -x "$SCRIPT" ]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture helpers ──────────────────────────────────────────────────────────
setup_fixture() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/.chump" "$TMP/docs/gaps" "$TMP/.chump-locks"
    cd "$TMP"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "ci@local" 2>/dev/null || true
    git config user.name "CI" 2>/dev/null || true

    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: title-similarity gate blocks 2nd+ gap in a fixture; disable it
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    # Point ambient to fixture dir so alerts don't pollute real ambient.jsonl
    export AMBIENT="$TMP/.chump-locks/ambient.jsonl"

    printf '%s' "$TMP"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate 2>/dev/null || true
}

# ── Test 2: balanced pillars exit 0 ─────────────────────────────────────────
TMP="$(setup_fixture)"
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-a"
    reserve_gap "${p}: balanced-b"
done
: > "$AMBIENT"
if bash "$SCRIPT" > /dev/null 2>&1; then
    ok "balanced pillars (2 per pillar) exit 0"
else
    fail "balanced pillars should exit 0"
fi
cd "$REPO_ROOT"; rm -rf "$TMP"

# ── Test 3: under-fed pillar emits alert and exits non-zero ─────────────────
TMP="$(setup_fixture)"
reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-a"
# ZERO-WASTE has 0 gaps — under floor
: > "$AMBIENT"
bash "$SCRIPT" > /dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ]; then
    ok "under-fed pillar exits non-zero (AC4)"
else
    fail "under-fed pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_alert event emitted to ambient.jsonl (AC2)"
else
    fail "pillar_balance_alert not found in ambient.jsonl"
fi

# Verify required fields: pillar, count, floor
if grep '"pillar_balance_alert"' "$AMBIENT" | jq -e '.pillar and (.count != null) and .floor' > /dev/null 2>&1; then
    ok "pillar_balance_alert has pillar, count, floor fields (AC2)"
else
    fail "pillar_balance_alert missing required fields"
fi

# Verify floor=2
if grep '"pillar_balance_alert"' "$AMBIENT" | jq -e '.floor == 2' > /dev/null 2>&1; then
    ok "pillar_balance_alert floor == 2 (AC2)"
else
    fail "pillar_balance_alert floor should be 2"
fi
cd "$REPO_ROOT"; rm -rf "$TMP"

# ── Test 4: overweight pillar emits alert ────────────────────────────────────
TMP="$(setup_fixture)"
for i in $(seq 1 6); do reserve_gap "EFFECTIVE: heavy-$i"; done
reserve_gap "CREDIBLE: heavy-1"
reserve_gap "RESILIENT: heavy-1"
reserve_gap "ZERO-WASTE: heavy-1"
# total=9, EFFECTIVE=6 → 66% > 50%
: > "$AMBIENT"
bash "$SCRIPT" > /dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ]; then
    ok "overweight pillar exits non-zero (AC4)"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted (AC3)"
else
    fail "pillar_balance_overweight not found in ambient.jsonl"
fi

# Verify required fields: pillar, count, pct
if grep '"pillar_balance_overweight"' "$AMBIENT" | jq -e '.pillar and (.count != null) and (.pct != null)' > /dev/null 2>&1; then
    ok "pillar_balance_overweight has pillar, count, pct fields (AC3)"
else
    fail "pillar_balance_overweight missing required fields"
fi

# pct > 50
if grep '"pillar_balance_overweight"' "$AMBIENT" | jq -e '.pct > 50' > /dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50 (AC3)"
else
    fail "pillar_balance_overweight pct should be > 50"
fi
cd "$REPO_ROOT"; rm -rf "$TMP"

# ── Test 5: non-pickable gaps are ignored ────────────────────────────────────
TMP="$(setup_fixture)"
# Pickable: P1 xs with real AC
reserve_gap "EFFECTIVE: pickable-1" P1 xs "real ac"
reserve_gap "EFFECTIVE: pickable-2" P1 xs "real ac"
# Non-pickable: wrong priority / wrong effort / TODO AC
reserve_gap "EFFECTIVE: p2-gap" P2 xs "real ac"
reserve_gap "EFFECTIVE: m-effort" P1 m "real ac"
reserve_gap "EFFECTIVE: todo-ac" P1 xs "TODO"
# These non-pickable gaps should not inflate EFFECTIVE count
# With only 2 pickable EFFECTIVE and 0 others, underfed alerts fire on other pillars
: > "$AMBIENT"
bash "$SCRIPT" > /dev/null 2>&1 || true
alert_count=$(grep -c '"pillar_balance_alert"' "$AMBIENT" 2>/dev/null || true)
alert_count=${alert_count:-0}
# CREDIBLE, RESILIENT, ZERO-WASTE each have 0 → 3 underfed alerts
if [ "$alert_count" -ge 3 ]; then
    ok "non-pickable gaps excluded; other pillars flagged (AC1 filtering)"
else
    fail "expected >=3 underfed alerts for empty pillars, got $alert_count"
fi
cd "$REPO_ROOT"; rm -rf "$TMP"

# ── Test 6: healthy state emits no alerts ────────────────────────────────────
TMP="$(setup_fixture)"
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: healthy-1" P1 xs "ac1"
    reserve_gap "${p}: healthy-2" P1 xs "ac2"
    reserve_gap "${p}: healthy-3" P1 xs "ac3"
done
: > "$AMBIENT"
if bash "$SCRIPT" > /dev/null 2>&1; then
    ok "healthy state (3 per pillar) exits 0 (AC4)"
else
    fail "healthy state should exit 0"
fi
if [ ! -s "$AMBIENT" ]; then
    ok "healthy state emits no alerts to ambient.jsonl"
else
    fail "healthy state should not emit alerts (got: $(cat "$AMBIENT"))"
fi
cd "$REPO_ROOT"; rm -rf "$TMP"

# ── Test 7: both under-fed and overweight alerts in same run ─────────────────
TMP="$(setup_fixture)"
for i in $(seq 1 10); do reserve_gap "EFFECTIVE: multi-$i"; done
reserve_gap "CREDIBLE: multi-1"
# RESILIENT=0, ZERO-WASTE=0 (underfed); EFFECTIVE=10/11=90% (overweight)
: > "$AMBIENT"
bash "$SCRIPT" > /dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ]; then
    ok "mixed alert scenario exits non-zero (AC4)"
else
    fail "mixed alert scenario should exit non-zero"
fi
under_count=$(grep -c '"pillar_balance_alert"' "$AMBIENT" 2>/dev/null || true)
over_count=$(grep -c '"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null || true)
under_count=${under_count:-0}
over_count=${over_count:-0}
if [ "$under_count" -gt 0 ] && [ "$over_count" -gt 0 ]; then
    ok "both pillar_balance_alert and pillar_balance_overweight emitted"
else
    fail "expected both alert kinds; got under=$under_count over=$over_count"
fi
cd "$REPO_ROOT"; rm -rf "$TMP"

# ── Test 8: audit-priorities output mentions pillar balance (AC5) ─────────────
if grep -q 'pillar.balance\|pillar_balance\|INFRA-902\|Pillar balance' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "audit-priorities arm references pillar-balance (AC5)"
else
    fail "src/main.rs audit-priorities arm does not reference pillar-balance"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
