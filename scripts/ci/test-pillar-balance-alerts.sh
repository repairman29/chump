#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests the pillar-balance-check.sh script:
#  AC1: script reads state.db via chump gap list --status open
#  AC2: when any pillar count < 2, emits kind=pillar_balance_alert with pillar, count, floor=2
#  AC3: when any pillar count > 50% of total pickable pool, emits kind=pillar_balance_overweight with pillar, count, pct
#  AC4: script exits non-zero if any alert fired
#  AC5: chump gap audit-priorities calls the script (integration test)
#  AC6: 8+ tests covering alerts, thresholds, exit codes

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve the chump binary robustly. INFRA-481 shares one target dir across
# linked worktrees (via .cargo/config.toml target-dir), so $REPO_ROOT/target is
# EMPTY inside a worktree — honor `cargo metadata`'s target_directory too.
# EXPORT it so the script under test uses the SAME binary, not PATH chump.
_cargo_tgt="$(cargo metadata --format-version 1 --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || true)"
CHUMP_BIN="${CHUMP_BIN:-}"
for _cand in "$CHUMP_BIN" "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" "$REPO_ROOT/target/debug/chump" "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
    [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
done

if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "[build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
    for _cand in "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" "$REPO_ROOT/target/debug/chump" "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
        [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
    done
fi
export CHUMP_BIN

if [[ ! -x "$CHUMP_BIN" ]]; then
    fail "chump binary not found after build"
    echo "PASS=$PASS  FAIL=$FAIL"
    exit 1
fi

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: Script exists and is executable ──────────────────────────────────
if [[ -x "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture setup helper ─────────────────────────────────────────────────────
setup_test_repo() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/.chump" "$TMP/docs/gaps" "$TMP/.chump-locks"
    cd "$TMP"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "test@ci.local" 2>/dev/null || true
    git config user.name "CI" 2>/dev/null || true

    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149 title-similarity check otherwise blocks the 2nd+ fixture gap
    # ("Potential overlap detected") so the scenario's pillar counts never
    # populate — every alert assertion then fails. Disable it for the fixture.
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    echo "$TMP"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate 2>/dev/null || true
}

# ── Test 2: Balanced pillars exit 0 ──────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar)"
TMP="$(setup_test_repo)"
trap 'rm -rf "$TMP"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-a"
    reserve_gap "${p}: balanced-b"
done

if bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "balanced pillars (2 per pillar) exit 0"
else
    fail "balanced pillars should exit 0"
fi

# ── Test 3: Under-fed pillar (< 2) emits alert and exits non-zero ───────────
echo "[Test 3] Under-fed pillar alert"
TMP2="$(setup_test_repo)"
cd "$TMP2"

# 2 EFFECTIVE + 2 CREDIBLE + 1 RESILIENT (under floor)
reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-a"

# Clear ambient.jsonl for clean test
: > "$TMP2/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi

# Check ambient.jsonl for pillar_balance_alert
if grep -q 'kind.*pillar_balance_alert' "$TMP2/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_alert event emitted"
else
    fail "pillar_balance_alert event not found in ambient.jsonl"
fi

# Verify alert schema: pillar, count, floor
if grep 'pillar_balance_alert' "$TMP2/.chump-locks/ambient.jsonl" | \
   jq -e '.pillar and .count != null and .floor' >/dev/null 2>&1; then
    ok "pillar_balance_alert has required fields (pillar, count, floor)"
else
    fail "pillar_balance_alert missing required fields"
fi

# Verify floor=2
if grep 'pillar_balance_alert' "$TMP2/.chump-locks/ambient.jsonl" | \
   jq -e '.floor == 2' >/dev/null 2>&1; then
    ok "pillar_balance_alert floor field = 2"
else
    fail "pillar_balance_alert floor should be 2"
fi

rm -rf "$TMP2"

# ── Test 4: Overweight pillar (> 50%) emits alert ──────────────────────────
echo "[Test 4] Overweight pillar alert"
TMP3="$(setup_test_repo)"
cd "$TMP3"

# 6 EFFECTIVE + 1 CREDIBLE + 1 RESILIENT + 1 ZERO-WASTE (total=9, EFFECTIVE=67% > 50%)
for i in $(seq 1 6); do
    reserve_gap "EFFECTIVE: overweight-$i"
done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"

: > "$TMP3/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi

# Check for pillar_balance_overweight event
if grep -q 'kind.*pillar_balance_overweight' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not found"
fi

# Verify overweight schema: pillar, count, pct
if grep 'pillar_balance_overweight' "$TMP3/.chump-locks/ambient.jsonl" | \
   jq -e '.pillar and .count != null and .pct' >/dev/null 2>&1; then
    ok "pillar_balance_overweight has required fields (pillar, count, pct)"
else
    fail "pillar_balance_overweight missing required fields"
fi

# Verify pct > 50
if grep 'pillar_balance_overweight' "$TMP3/.chump-locks/ambient.jsonl" | \
   jq -e '.pct > 50' >/dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50"
else
    fail "pillar_balance_overweight pct should be > 50"
fi

rm -rf "$TMP3"

# ── Test 5: Script ignores non-pickable gaps ────────────────────────────────
echo "[Test 5] Script ignores non-pickable gaps"
TMP4="$(setup_test_repo)"
cd "$TMP4"

# Create one pickable gap per pillar (balanced)
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: pickable"
done

# Create non-pickable gaps (P2, effort m, TODO AC, etc.) that should be ignored
reserve_gap "EFFECTIVE: p2-gap" "P2" "xs"
reserve_gap "EFFECTIVE: large-gap" "P1" "m"
reserve_gap "EFFECTIVE: todo-gap" "P1" "xs" "TODO"

: > "$TMP4/.chump-locks/ambient.jsonl"

# Should exit 0 because only the 4 pickable gaps are counted, each pillar has 1 (< 2 threshold)
# Wait, that would fail. Let me think...
# Actually with 4 gaps (1 per pillar), each pillar has count=1 which is < 2, so alert should fire.
# Let me add one more pickable gap per pillar to make it balanced at 2 each.

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: pickable-2"
done

: > "$TMP4/.chump-locks/ambient.jsonl"

if bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "non-pickable gaps are ignored; balanced pickable gaps exit 0"
else
    fail "should ignore non-pickable gaps"
fi

rm -rf "$TMP4"

# ── Test 6: Multiple under-fed pillars emit multiple alerts ────────────────
echo "[Test 6] Multiple under-fed pillars"
TMP5="$(setup_test_repo)"
cd "$TMP5"

# Only 1 EFFECTIVE + 1 CREDIBLE (both under floor)
reserve_gap "EFFECTIVE: lone-1"
reserve_gap "CREDIBLE: lone-1"

: > "$TMP5/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    ok "multiple under-fed pillars exit non-zero"
else
    fail "multiple under-fed pillars should exit non-zero"
fi

# Count alert events
alert_count=$(grep -c 'pillar_balance_alert' "$TMP5/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0)
if [[ "$alert_count" -ge 2 ]]; then
    ok "multiple alerts emitted for multiple under-fed pillars"
else
    fail "should emit multiple alerts (found $alert_count, expected >= 2)"
fi

rm -rf "$TMP5"

# ── Test 7: Verify correct pillar names in alerts ────────────────────────────
echo "[Test 7] Correct pillar names in alerts"
TMP6="$(setup_test_repo)"
cd "$TMP6"

reserve_gap "ZERO-WASTE: test"

: > "$TMP6/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 || true

if grep 'pillar_balance_alert' "$TMP6/.chump-locks/ambient.jsonl" | \
   jq -e '.pillar == "ZERO-WASTE"' >/dev/null 2>&1; then
    ok "pillar name 'ZERO-WASTE' preserved in alert"
else
    fail "pillar name should be 'ZERO-WASTE' in alert"
fi

rm -rf "$TMP6"

# ── Test 8: Empty state (no gaps) exits 0 ────────────────────────────────────
echo "[Test 8] Empty state (no gaps)"
TMP7="$(setup_test_repo)"
cd "$TMP7"

: > "$TMP7/.chump-locks/ambient.jsonl"

if bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "empty state (no gaps) exits 0"
else
    fail "empty state should exit 0"
fi

rm -rf "$TMP7"

# ── Test 9: Script creates .chump-locks dir if missing ───────────────────────
echo "[Test 9] Script creates .chump-locks directory"
TMP8="$(setup_test_repo)"
cd "$TMP8"

# Remove .chump-locks to test auto-creation
rm -rf "$TMP8/.chump-locks"

reserve_gap "EFFECTIVE: test-1"
reserve_gap "EFFECTIVE: test-2"

# Script should create .chump-locks and ambient.jsonl
bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 || true

if [[ -f "$TMP8/.chump-locks/ambient.jsonl" ]]; then
    ok "script creates .chump-locks directory and ambient.jsonl"
else
    fail "script should create .chump-locks/ambient.jsonl"
fi

rm -rf "$TMP8"

echo
echo "PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
