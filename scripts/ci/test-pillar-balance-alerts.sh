#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests pillar-balance-check.sh (AC1-AC6):
#  AC1: script reads state.db via chump gap list --status open
#  AC2: when any pillar count < 2, emits kind=pillar_balance_alert with pillar, count, floor=2
#  AC3: when any pillar count > 50% of total, emits kind=pillar_balance_overweight with pillar, count, pct
#  AC4: script exits non-zero if any alert fired
#  AC5: chump gap audit-priorities calls pillar-balance-check.sh
#  AC6: 8+ tests covering alerts, thresholds, exit codes

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve chump binary (INFRA-481: shared target-dir via .cargo/config.toml;
# $REPO_ROOT/target is empty in linked worktrees — honor cargo metadata too).
_cargo_tgt="$(cargo metadata --format-version 1 --no-deps \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null \
    || true)"

CHUMP_BIN="${CHUMP_BIN:-}"
for _cand in \
    "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
    "$REPO_ROOT/target/debug/chump" \
    "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
    [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
done

if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "[build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
    for _cand in \
        "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
        "$REPO_ROOT/target/debug/chump" \
        "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
        [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
    done
fi

# Export so pillar-balance-check.sh uses the SAME binary, not PATH chump
export CHUMP_BIN

if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "FATAL: chump binary not found after build" >&2
    exit 2
fi

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: Script exists and is executable ──────────────────────────────────
if [[ -x "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture helpers ──────────────────────────────────────────────────────────
setup_repo() {
    local _tmp
    _tmp="$(mktemp -d)"
    mkdir -p "$_tmp/.chump" "$_tmp/docs/gaps" "$_tmp/.chump-locks"
    cd "$_tmp"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "test@ci.local" 2>/dev/null || true
    git config user.name "CI" 2>/dev/null || true

    export CHUMP_REPO="$_tmp"
    export CHUMP_WORKTREE_ROOT="$_tmp"
    export CHUMP_HOME="$_tmp"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: disable title-similarity check so 2nd+ fixture gap isn't blocked
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export CHUMP_BINARY_STALENESS_CHECK=0

    echo "$_tmp"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate >/dev/null 2>&1 || true
}

run_check() {
    local ambient="$1"
    : > "$ambient"
    AMBIENT="$ambient" bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1
}

# ── Test 2: Balanced pillars (2 per pillar) exit 0 ──────────────────────────
echo "[Test 2] Balanced pillars"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-a"
    reserve_gap "${p}: balanced-b"
done

if AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
   bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "balanced pillars (2 per pillar) exit 0"
else
    fail "balanced pillars should exit 0"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 3: Under-fed pillar emits pillar_balance_alert and exits non-zero ──
echo "[Test 3] Under-fed pillar alert"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-only"
# ZERO-WASTE has 0 — under floor

AMB="$TMP/.chump-locks/ambient.jsonl"
: > "$AMB"
AMBIENT="$AMB" bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && _ec=0 || _ec=$?

if [[ "$_ec" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero (AC4)"
else
    fail "under-fed pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_alert"' "$AMB" 2>/dev/null; then
    ok "pillar_balance_alert event emitted (AC2)"
else
    fail "pillar_balance_alert event not found in ambient.jsonl"
fi

if grep '"pillar_balance_alert"' "$AMB" | \
   python3 -c 'import sys,json; d=json.loads(sys.stdin.read().strip()); assert "pillar" in d and "count" in d and d.get("floor")==2' 2>/dev/null; then
    ok "pillar_balance_alert has required fields: pillar, count, floor=2 (AC2)"
else
    fail "pillar_balance_alert missing required fields or floor!=2"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 4: Overweight pillar emits pillar_balance_overweight ───────────────
echo "[Test 4] Overweight pillar alert"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

# 6 EFFECTIVE + 1 each of others = 9 total; EFFECTIVE = 67% > 50%
for i in 1 2 3 4 5 6; do
    reserve_gap "EFFECTIVE: overweight-$i"
done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"

AMB="$TMP/.chump-locks/ambient.jsonl"
: > "$AMB"
AMBIENT="$AMB" bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && _ec=0 || _ec=$?

if [[ "$_ec" -ne 0 ]]; then
    ok "overweight pillar exits non-zero (AC4)"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$AMB" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted (AC3)"
else
    fail "pillar_balance_overweight event not found"
fi

if grep '"pillar_balance_overweight"' "$AMB" | \
   python3 -c 'import sys,json; d=json.loads(sys.stdin.read().strip()); assert "pillar" in d and "count" in d and "pct" in d and d["pct"]>50' 2>/dev/null; then
    ok "pillar_balance_overweight has required fields and pct>50 (AC3)"
else
    fail "pillar_balance_overweight missing required fields or pct<=50"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 5: Non-pickable gaps are excluded ───────────────────────────────────
echo "[Test 5] Non-pickable gaps excluded"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

# 2 pickable per pillar
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: pick-a"
    reserve_gap "${p}: pick-b"
done
# Non-pickable (P2, large effort, TODO AC) should not count
reserve_gap "EFFECTIVE: p2-ignored" "P2" "xs"
reserve_gap "EFFECTIVE: large-ignored" "P1" "m"
reserve_gap "EFFECTIVE: todo-ignored" "P1" "xs" "TODO"

AMB="$TMP/.chump-locks/ambient.jsonl"
: > "$AMB"

if AMBIENT="$AMB" bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "non-pickable gaps excluded; balanced pickable set exits 0"
else
    fail "should exclude non-pickable gaps and exit 0"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 6: Multiple under-fed pillars emit multiple alerts ─────────────────
echo "[Test 6] Multiple under-fed pillars"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

reserve_gap "EFFECTIVE: lone"
reserve_gap "CREDIBLE: lone"
# RESILIENT and ZERO-WASTE have 0

AMB="$TMP/.chump-locks/ambient.jsonl"
: > "$AMB"
AMBIENT="$AMB" bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && _ec=0 || _ec=$?

if [[ "$_ec" -ne 0 ]]; then
    ok "multiple under-fed pillars exit non-zero"
else
    fail "multiple under-fed pillars should exit non-zero"
fi

_alert_count=$(grep -c '"pillar_balance_alert"' "$AMB" 2>/dev/null || echo 0)
if [[ "$_alert_count" -ge 3 ]]; then
    ok "multiple alerts emitted ($_alert_count) for multiple under-fed pillars"
else
    fail "expected >= 3 alerts, got $_alert_count"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 7: Empty state exits 0 (no gaps = no alerts) ───────────────────────
echo "[Test 7] Empty state exits 0"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/.chump-locks/ambient.jsonl"
: > "$AMB"

if AMBIENT="$AMB" bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "empty gap registry exits 0 (no alerts when no gaps)"
else
    fail "empty state should exit 0"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 8: Script creates .chump-locks dir if missing ──────────────────────
echo "[Test 8] Script creates .chump-locks directory"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$TMP/.chump-locks"
reserve_gap "EFFECTIVE: test-1"
reserve_gap "EFFECTIVE: test-2"

# Script must create the dir and ambient.jsonl
AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
    bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 || true

if [[ -d "$TMP/.chump-locks" ]]; then
    ok "script creates .chump-locks/ directory when missing"
else
    fail "script should create .chump-locks/"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 9: ZERO-WASTE pillar name preserved in alert ───────────────────────
echo "[Test 9] ZERO-WASTE pillar name in alert"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

reserve_gap "ZERO-WASTE: only-one"
# All other pillars also under floor

AMB="$TMP/.chump-locks/ambient.jsonl"
: > "$AMB"
AMBIENT="$AMB" bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 || true

if grep '"pillar_balance_alert"' "$AMB" | grep -q '"ZERO-WASTE"' 2>/dev/null; then
    ok "ZERO-WASTE pillar name preserved in alert"
else
    fail "ZERO-WASTE pillar name missing from alert"
fi

trap - EXIT
rm -rf "$TMP"

# ── Test 10: audit-priorities calls pillar-balance-check.sh (AC5) ───────────
echo "[Test 10] audit-priorities includes pillar-balance result"
TMP="$(setup_repo)"
trap 'rm -rf "$TMP"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: ap-test-a" P1 xs
    reserve_gap "${p}: ap-test-b" P1 xs
done

_audit_out=$(CHUMP_REPO="$TMP" "$CHUMP_BIN" gap audit-priorities 2>&1 || true)

if echo "$_audit_out" | grep -qi "pillar"; then
    ok "audit-priorities output includes pillar balance section (AC5)"
else
    fail "audit-priorities should include pillar balance result — got: $(echo "$_audit_out" | tail -5)"
fi

trap - EXIT
rm -rf "$TMP"

echo
echo "=== Results: PASS=$PASS  FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
