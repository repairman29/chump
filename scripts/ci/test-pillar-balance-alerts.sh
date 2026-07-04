#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh.
# 8+ tests covering: alert schema, thresholds, exit codes (AC6).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  ok  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

# Resolve chump binary via cargo metadata (honors shared target-dir, INFRA-481)
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-}"
if [[ -z "$CARGO_TARGET_DIR" ]]; then
    CARGO_TARGET_DIR="$(cargo metadata --no-deps --format-version 1 \
        --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
        | jq -r '.target_directory' 2>/dev/null || echo "$REPO_ROOT/target")"
fi
export CARGO_TARGET_DIR

CHUMP_BIN_PATH="$CARGO_TARGET_DIR/debug/chump"
if [[ ! -x "$CHUMP_BIN_PATH" ]]; then
    echo "[build] building chump binary..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -x "$CHUMP_BIN_PATH" ]]; then
    fail "chump binary not found after build at $CHUMP_BIN_PATH"
    echo "PASS=$PASS  FAIL=$FAIL"
    exit 1
fi

# Export so subshells (the script under test) see our fixture binary
export CHUMP_BIN="$CHUMP_BIN_PATH"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: Script exists and is executable ──────────────────────────────────
echo "[T1] Script exists"
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture setup helpers ────────────────────────────────────────────────────
setup_test_repo() {
    local TMP
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/.chump" "$TMP/.chump-locks" "$TMP/docs/gaps"
    cd "$TMP"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "test@ci.local" 2>/dev/null || true
    git config user.name "CI" 2>/dev/null || true

    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export AMBIENT="$TMP/.chump-locks/ambient.jsonl"
    # INFRA-1149: block similarity check so 2nd+ reserve of same pillar doesn't fail
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0

    : > "$TMP/.chump-locks/ambient.jsonl"
    echo "$TMP"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" 2>/dev/null || true
}

# ── Test 2: Balanced pillars exit 0 ──────────────────────────────────────────
echo "[T2] Balanced pillars exit 0"
TMP="$(setup_test_repo)"
CLEANUP="$TMP"
trap 'rm -rf "$CLEANUP"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balance-a"
    reserve_gap "${p}: balance-b"
done

if bash "$SCRIPT" > /dev/null 2>&1; then
    ok "balanced pillars (2 each) exit 0"
else
    fail "balanced pillars should exit 0 (got non-zero)"
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 3: Under-fed pillar exits non-zero ──────────────────────────────────
echo "[T3] Under-fed pillar exits non-zero"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

reserve_gap "EFFECTIVE: fed-a"
reserve_gap "EFFECTIVE: fed-b"
reserve_gap "CREDIBLE: fed-a"
reserve_gap "CREDIBLE: fed-b"
reserve_gap "RESILIENT: fed-a"
# ZERO-WASTE has 0 gaps → under-fed

bash "$SCRIPT" > /dev/null 2>&1 && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 4: Under-fed alert emitted to ambient.jsonl ────────────────────────
echo "[T4] Under-fed emits pillar_balance_alert"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

reserve_gap "EFFECTIVE: alert-a"
reserve_gap "EFFECTIVE: alert-b"
reserve_gap "CREDIBLE: alert-a"
reserve_gap "CREDIBLE: alert-b"
reserve_gap "RESILIENT: alert-a"
# ZERO-WASTE has 0 gaps

bash "$SCRIPT" > /dev/null 2>&1 || true

if grep -q '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_alert emitted to ambient.jsonl"
else
    fail "pillar_balance_alert not found in ambient.jsonl"
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 5: Alert schema has required fields ─────────────────────────────────
echo "[T5] Alert schema: pillar, count, floor=2"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

reserve_gap "EFFECTIVE: schema-a"
reserve_gap "EFFECTIVE: schema-b"
reserve_gap "CREDIBLE: schema-a"
reserve_gap "CREDIBLE: schema-b"
reserve_gap "RESILIENT: schema-a"

bash "$SCRIPT" > /dev/null 2>&1 || true

alert_line=$(grep '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null | head -1 || echo "")
if [[ -n "$alert_line" ]]; then
    if printf '%s' "$alert_line" | jq -e '.pillar and (.count != null) and (.floor == 2)' > /dev/null 2>&1; then
        ok "pillar_balance_alert has pillar, count, floor=2"
    else
        fail "pillar_balance_alert missing required field(s) or floor != 2: $alert_line"
    fi
else
    fail "no pillar_balance_alert found (schema check skipped)"
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 6: Overweight pillar exits non-zero and emits overweight event ──────
echo "[T6] Overweight pillar alert"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

# 6 EFFECTIVE + 1 each of others → EFFECTIVE = 6/9 = 66% > 50%
for i in 1 2 3 4 5 6; do
    reserve_gap "EFFECTIVE: heavy-$i"
done
reserve_gap "CREDIBLE: one"
reserve_gap "RESILIENT: one"
reserve_gap "ZERO-WASTE: one"

bash "$SCRIPT" > /dev/null 2>&1 && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_overweight emitted"
else
    fail "pillar_balance_overweight not found in ambient.jsonl"
fi

ow_line=$(grep '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null | head -1 || echo "")
if [[ -n "$ow_line" ]]; then
    if printf '%s' "$ow_line" | jq -e '.pillar and (.count != null) and (.pct > 50)' > /dev/null 2>&1; then
        ok "pillar_balance_overweight has pillar, count, pct>50"
    else
        fail "pillar_balance_overweight schema invalid: $ow_line"
    fi
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 7: Non-pickable gaps are ignored ────────────────────────────────────
echo "[T7] Non-pickable gaps ignored"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

# 2 pickable EFFECTIVE
reserve_gap "EFFECTIVE: pickable-a" P1 xs "verify it"
reserve_gap "EFFECTIVE: pickable-b" P1 xs "verify it"
# Non-pickable: P2 (wrong priority)
reserve_gap "EFFECTIVE: nonpick-p2" P2 xs "verify it"
# Non-pickable: m effort (too large)
reserve_gap "EFFECTIVE: nonpick-m" P1 m "verify it"
# Non-pickable: TODO AC
reserve_gap "EFFECTIVE: nonpick-todo" P1 xs "TODO"

# 2 per other pillars for balance
for p in CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: ctrl-a" P1 xs "verify it"
    reserve_gap "${p}: ctrl-b" P1 xs "verify it"
done

bash "$SCRIPT" > /dev/null 2>&1 && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "non-pickable gaps ignored (balanced with 2 pickable EFFECTIVE)"
else
    fail "expected exit 0 but got $rc (non-pickable gaps may be counted)"
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 8: Empty gap store exits non-zero (all pillars under floor) ─────────
echo "[T8] Empty gap store fires all-pillar alerts"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

bash "$SCRIPT" > /dev/null 2>&1 && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "empty store exits non-zero"
else
    fail "empty store should exit non-zero"
fi

alert_count=$(grep -c '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null || echo "0")
if [[ "$alert_count" -ge 4 ]]; then
    ok "all 4 pillars fire under-floor alerts when store is empty"
else
    fail "expected >= 4 pillar_balance_alert events, got $alert_count"
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 9: Exactly floor=2 per pillar exits 0 ───────────────────────────────
echo "[T9] Exactly floor=2 per pillar exits 0 (boundary)"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: boundary-a" P1 xs "check it"
    reserve_gap "${p}: boundary-b" P1 xs "check it"
done

bash "$SCRIPT" > /dev/null 2>&1 && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "exactly 2 per pillar exits 0 (floor boundary)"
else
    fail "exactly 2 per pillar should exit 0 (got $rc)"
fi
trap - EXIT; rm -rf "$TMP"

# ── Test 10: 50% exactly is NOT overweight (>50 threshold) ──────────────────
echo "[T10] Exactly 50% is not overweight (threshold is strictly >50)"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

# 2 EFFECTIVE, 2 CREDIBLE → EFFECTIVE = 50%, which should NOT trigger overweight
reserve_gap "EFFECTIVE: half-a" P1 xs "check it"
reserve_gap "EFFECTIVE: half-b" P1 xs "check it"
reserve_gap "CREDIBLE: half-a" P1 xs "check it"
reserve_gap "CREDIBLE: half-b" P1 xs "check it"
# RESILIENT and ZERO-WASTE = 0 → will trigger under-floor alerts, but no overweight

bash "$SCRIPT" > /dev/null 2>&1 || true

ow_count=$(grep -c '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null || echo "0")
if [[ "$ow_count" -eq 0 ]]; then
    ok "50% does not trigger overweight (threshold strictly >50)"
else
    fail "50% should not trigger overweight, but got $ow_count overweight events"
fi
trap - EXIT; rm -rf "$TMP"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: PASS=$PASS  FAIL=$FAIL ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
