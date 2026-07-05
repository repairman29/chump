#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# 8+ tests verifying pillar-balance-check.sh:
#   1. Script is executable
#   2. Balanced fixture (>=2 per pillar, no dominant): exit 0, no alerts
#   3. Under-filled pillar: emits kind=pillar_balance_alert, exit 1
#   4. alert JSON has required fields: pillar, count, floor
#   5. Overweight pillar: emits kind=pillar_balance_overweight, exit 1
#   6. overweight JSON has required fields: pillar, count, pct
#   7. Exactly at floor (2 gaps each): exit 0, no alerts
#   8. Multiple pillars under-filled: multiple pillar_balance_alert events
#   9. --json flag: emits JSON summary with pillars/total_pickable fields
#  10. P2 gaps excluded from pickable count

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-check.sh tests ==="
echo

# ── 1. Script exists and is executable ───────────────────────────────────────
echo "[1. script executable]"
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh is executable"
else
    fail "pillar-balance-check.sh not found or not executable at $SCRIPT"
fi

# ── Resolve binary (shared target-dir per INFRA-481) ─────────────────────────
if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "${CHUMP_BIN}" ]]; then
    BIN="$CHUMP_BIN"
elif CARGO_TARGET="$(cargo metadata --no-deps --format-version 1 \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null)"; then
    if [[ -x "${CARGO_TARGET}/debug/chump" ]]; then
        BIN="${CARGO_TARGET}/debug/chump"
    elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
        BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    else
        BIN="${CARGO_TARGET}/debug/chump"
    fi
else
    BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
fi

if [[ ! -x "$BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
fi

if [[ ! -x "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

export CHUMP_BIN="$BIN"

# ── Fixture helpers ───────────────────────────────────────────────────────────
make_tmpdir() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump-locks"
    export CHUMP_REPO="$tmp"
    export CHUMP_HOME="$tmp"
    export CHUMP_AMBIENT_LOG="$tmp/.chump-locks/ambient.jsonl"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    echo "$tmp"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    "$BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --quiet --force-duplicate 2>/dev/null
}

# ── 2. Balanced fixture: exit 0, no alerts ───────────────────────────────────
echo
echo "[2. balanced fixture — exit 0]"
TMP2="$(make_tmpdir)"
trap 'rm -rf "$TMP2"' EXIT

for p in "EFFECTIVE:" "CREDIBLE:" "RESILIENT:" "ZERO-WASTE:"; do
    reserve_gap "${p} fixture-gap-a P1/xs"
    reserve_gap "${p} fixture-gap-b P1/xs"
done

AMBIENT2="$CHUMP_AMBIENT_LOG"
if bash "$SCRIPT" 2>/dev/null; then
    ok "balanced fixture exits 0"
else
    fail "balanced fixture should exit 0"
fi

ALERT_COUNT2=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT2" 2>/dev/null || echo 0)
if [[ "$ALERT_COUNT2" -eq 0 ]]; then
    ok "balanced fixture: no pillar_balance_alert events"
else
    fail "balanced fixture: unexpected pillar_balance_alert (count=$ALERT_COUNT2)"
fi

rm -rf "$TMP2"

# ── 3. Under-filled pillar: exit 1, alert emitted ────────────────────────────
echo
echo "[3. under-filled pillar — exit 1]"
TMP3="$(make_tmpdir)"
trap 'rm -rf "$TMP3"' EXIT

# Only 1 EFFECTIVE gap (below floor of 2); others have 2 each
reserve_gap "EFFECTIVE: fixture-gap-a P1/xs"
for p in "CREDIBLE:" "RESILIENT:" "ZERO-WASTE:"; do
    reserve_gap "${p} fixture-gap-a P1/xs"
    reserve_gap "${p} fixture-gap-b P1/xs"
done

AMBIENT3="$CHUMP_AMBIENT_LOG"
if bash "$SCRIPT" 2>/dev/null; then
    fail "under-filled pillar should exit 1"
else
    ok "under-filled pillar exits 1"
fi

ALERT_COUNT3=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT3" 2>/dev/null || echo 0)
if [[ "$ALERT_COUNT3" -ge 1 ]]; then
    ok "under-filled pillar: pillar_balance_alert emitted (count=$ALERT_COUNT3)"
else
    fail "under-filled pillar: pillar_balance_alert not emitted"
fi

# ── 4. Alert JSON has required fields ────────────────────────────────────────
echo
echo "[4. alert JSON fields]"
ALERT_LINE=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT3" | head -1)
for field in '"pillar"' '"count"' '"floor"'; do
    if echo "$ALERT_LINE" | grep -q "$field"; then
        ok "alert JSON has $field field"
    else
        fail "alert JSON missing $field — line: $ALERT_LINE"
    fi
done

rm -rf "$TMP3"

# ── 5. Overweight pillar: exit 1, overweight emitted ─────────────────────────
echo
echo "[5. overweight pillar — exit 1]"
TMP5="$(make_tmpdir)"
trap 'rm -rf "$TMP5"' EXIT

# 8 EFFECTIVE gaps out of 10 total = 80% > 50% threshold
for i in 1 2 3 4 5 6 7 8; do
    reserve_gap "EFFECTIVE: fixture-overweight-$i P1/xs"
done
reserve_gap "CREDIBLE: fixture-gap-a P1/xs"
reserve_gap "RESILIENT: fixture-gap-a P1/xs"
# ZERO-WASTE: 0 → also fires alert; CREDIBLE/RESILIENT = 1 each → alert too
# That's fine — we only need overweight to fire for EFFECTIVE

AMBIENT5="$CHUMP_AMBIENT_LOG"
bash "$SCRIPT" 2>/dev/null || true  # will exit 1

OW_COUNT=$(grep -c '"kind":"pillar_balance_overweight"' "$AMBIENT5" 2>/dev/null || echo 0)
if [[ "$OW_COUNT" -ge 1 ]]; then
    ok "overweight pillar: pillar_balance_overweight emitted (count=$OW_COUNT)"
else
    fail "overweight pillar: pillar_balance_overweight not emitted"
fi

if bash "$SCRIPT" 2>/dev/null; then
    fail "overweight fixture should exit 1"
else
    ok "overweight fixture exits 1"
fi

# ── 6. Overweight JSON has required fields ────────────────────────────────────
echo
echo "[6. overweight JSON fields]"
OW_LINE=$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT5" | head -1)
for field in '"pillar"' '"count"' '"pct"'; do
    if echo "$OW_LINE" | grep -q "$field"; then
        ok "overweight JSON has $field field"
    else
        fail "overweight JSON missing $field — line: $OW_LINE"
    fi
done

rm -rf "$TMP5"

# ── 7. Exactly at floor (2 each): exit 0 ────────────────────────────────────
echo
echo "[7. exactly at floor — exit 0]"
TMP7="$(make_tmpdir)"
trap 'rm -rf "$TMP7"' EXIT

for p in "EFFECTIVE:" "CREDIBLE:" "RESILIENT:" "ZERO-WASTE:"; do
    reserve_gap "${p} at-floor-a P1/xs"
    reserve_gap "${p} at-floor-b P1/xs"
done

if bash "$SCRIPT" 2>/dev/null; then
    ok "exactly at floor exits 0"
else
    fail "exactly at floor should exit 0"
fi

rm -rf "$TMP7"

# ── 8. Multiple pillars under-filled: multiple alerts ────────────────────────
echo
echo "[8. multiple under-filled pillars — multiple alerts]"
TMP8="$(make_tmpdir)"
trap 'rm -rf "$TMP8"' EXIT

# Only EFFECTIVE has 2+; CREDIBLE, RESILIENT, ZERO-WASTE have 0 each
reserve_gap "EFFECTIVE: fixture-multi-a P1/xs"
reserve_gap "EFFECTIVE: fixture-multi-b P1/xs"

AMBIENT8="$CHUMP_AMBIENT_LOG"
bash "$SCRIPT" 2>/dev/null || true  # will exit 1

MULTI_COUNT=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT8" 2>/dev/null || echo 0)
if [[ "$MULTI_COUNT" -ge 3 ]]; then
    ok "multiple under-filled: $MULTI_COUNT alerts emitted (expected >=3)"
else
    fail "multiple under-filled: expected >=3 alerts, got $MULTI_COUNT"
fi

rm -rf "$TMP8"

# ── 9. --json flag emits JSON summary ────────────────────────────────────────
echo
echo "[9. --json output]"
TMP9="$(make_tmpdir)"
trap 'rm -rf "$TMP9"' EXIT

for p in "EFFECTIVE:" "CREDIBLE:" "RESILIENT:" "ZERO-WASTE:"; do
    reserve_gap "${p} json-test-a P1/xs"
    reserve_gap "${p} json-test-b P1/xs"
done

JSON_OUT=$(bash "$SCRIPT" --json 2>/dev/null)
for key in '"pillars"' '"total_pickable"' '"floor"' '"alerts_fired"'; do
    if echo "$JSON_OUT" | grep -q "$key"; then
        ok "--json output has $key"
    else
        fail "--json output missing $key — got: $JSON_OUT"
    fi
done

rm -rf "$TMP9"

# ── 10. P2 gaps excluded from pickable count ─────────────────────────────────
echo
echo "[10. P2 gaps excluded from pickable]"
TMP10="$(make_tmpdir)"
trap 'rm -rf "$TMP10"' EXIT

# 2 P1 gaps per pillar (pickable) + 10 P2 EFFECTIVE gaps (not pickable)
for p in "EFFECTIVE:" "CREDIBLE:" "RESILIENT:" "ZERO-WASTE:"; do
    reserve_gap "${p} p2-excl-a P1/xs"
    reserve_gap "${p} p2-excl-b P1/xs"
done
for i in 1 2 3 4 5 6 7 8 9 10; do
    reserve_gap "EFFECTIVE: p2-noise-$i P2/xs"
done

# With P2 excluded, EFFECTIVE = 2 = floor, not overweight; all pillars fine
if bash "$SCRIPT" 2>/dev/null; then
    ok "P2 gaps excluded: balanced fixture still exits 0 despite 10 P2 EFFECTIVE gaps"
else
    fail "P2 gaps excluded: should exit 0 when P2 gaps don't count toward pickable"
fi

rm -rf "$TMP10"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
