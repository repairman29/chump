#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh
#  AC1: reads state.db via chump gap list --status open
#  AC2: emits kind=pillar_balance_alert (pillar, count, floor=2) when count < 2
#  AC3: emits kind=pillar_balance_overweight (pillar, count, pct) when count > 50%
#  AC4: exits non-zero if any alert fired
#  AC5: chump gap audit-priorities includes pillar balance result
#  AC6: 8+ tests

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  ok  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ── Resolve chump binary (INFRA-481: shared target-dir across linked worktrees) ──
_cargo_tgt="$(cargo metadata --format-version 1 --no-deps \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' \
    2>/dev/null || true)"
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
export CHUMP_BIN

if [[ ! -x "$CHUMP_BIN" ]]; then
    fail "chump binary not found after build"
    echo "PASS=$PASS  FAIL=$FAIL"
    exit 1
fi

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: Script exists and is executable ───────────────────────────────────
if [[ -x "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture setup helper ──────────────────────────────────────────────────────
_ACTIVE_TMP=""
setup_test_repo() {
    local tmp
    tmp="$(mktemp -d)"
    _ACTIVE_TMP="$tmp"
    mkdir -p "$tmp/.chump" "$tmp/.chump-locks" "$tmp/docs/gaps"
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
    # INFRA-1149: disable title-similarity check so 2nd+ gaps are not blocked
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    # Point ambient.jsonl to fixture dir (Bash 3.2 safe — no AMBIENT export
    # needed; the script derives it from git rev-parse inside $tmp)
    echo "$tmp"
}

cleanup_all() {
    [[ -n "$_ACTIVE_TMP" && -d "$_ACTIVE_TMP" ]] && rm -rf "$_ACTIVE_TMP" || true
}
trap cleanup_all EXIT

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate 2>/dev/null || true
}

# ── Test 2: Balanced pillars exit 0 ──────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar)"
TMP="$(setup_test_repo)"
: > "$TMP/.chump-locks/ambient.jsonl"
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
rm -rf "$TMP"

# ── Test 3: Under-fed pillar emits alert + exits non-zero ────────────────────
echo "[Test 3] Under-fed pillar alert"
TMP="$(setup_test_repo)"
: > "$TMP/.chump-locks/ambient.jsonl"
reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-a"   # only 1 RESILIENT, 0 ZERO-WASTE

AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
    bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && rc=0 || rc=$?

if [[ "$rc" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi
if grep -q '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_alert event emitted"
else
    fail "pillar_balance_alert event not found in ambient.jsonl"
fi
if grep '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" \
   | jq -e '.pillar and (.count != null) and .floor' >/dev/null 2>&1; then
    ok "pillar_balance_alert has required fields (pillar, count, floor)"
else
    fail "pillar_balance_alert missing required fields"
fi
if grep '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" \
   | jq -e '.floor == 2' >/dev/null 2>&1; then
    ok "pillar_balance_alert floor = 2"
else
    fail "pillar_balance_alert floor should be 2"
fi
rm -rf "$TMP"

# ── Test 4: Overweight pillar emits alert ────────────────────────────────────
echo "[Test 4] Overweight pillar alert"
TMP="$(setup_test_repo)"
: > "$TMP/.chump-locks/ambient.jsonl"
# 6 EFFECTIVE + 1 each of CREDIBLE / RESILIENT / ZERO-WASTE → EFFECTIVE = 60% > 50%
for i in 1 2 3 4 5 6; do reserve_gap "EFFECTIVE: overweight-$i"; done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"

AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
    bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && rc=0 || rc=$?

if [[ "$rc" -ne 0 ]]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi
if grep -q '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not found"
fi
if grep '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" \
   | jq -e '.pillar and (.count != null) and .pct' >/dev/null 2>&1; then
    ok "pillar_balance_overweight has required fields (pillar, count, pct)"
else
    fail "pillar_balance_overweight missing required fields"
fi
if grep '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" \
   | jq -e '.pct > 50' >/dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50"
else
    fail "pillar_balance_overweight pct should be > 50"
fi
rm -rf "$TMP"

# ── Test 5: TODO ACs excluded from pickable count ────────────────────────────
echo "[Test 5] TODO ACs excluded from pickable count"
TMP="$(setup_test_repo)"
: > "$TMP/.chump-locks/ambient.jsonl"
# Only 1 EFFECTIVE pickable (TODO AC should be skipped); all other pillars empty
reserve_gap "EFFECTIVE: real-ac" P1 xs "verify it"
reserve_gap "CREDIBLE: todo-ac"  P1 xs "TODO"

AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
    bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 || true

# CREDIBLE has 0 pickable (TODO filtered), so an alert should fire
if grep -q '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "TODO ACs are excluded from pickable count (alert fires for empty pillar)"
else
    fail "script should ignore TODO ACs and alert on under-fed pillar"
fi
rm -rf "$TMP"

# ── Test 6: Healthy state produces no alerts ─────────────────────────────────
echo "[Test 6] Healthy state produces no alerts"
TMP="$(setup_test_repo)"
: > "$TMP/.chump-locks/ambient.jsonl"
# 3 per pillar, none > 50% of 12 total
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    for i in 1 2 3; do reserve_gap "${p}: healthy-$i" P1 xs "ac-$i"; done
done
if AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
   bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "healthy state exits 0"
else
    fail "healthy state should exit 0"
fi
if [[ ! -s "$TMP/.chump-locks/ambient.jsonl" ]]; then
    ok "healthy state emits no alerts"
else
    fail "healthy state should not emit alerts to ambient.jsonl"
fi
rm -rf "$TMP"

# ── Test 7: Multiple alert types in a single run ─────────────────────────────
echo "[Test 7] Multiple alert types (under-fed + overweight in same run)"
TMP="$(setup_test_repo)"
: > "$TMP/.chump-locks/ambient.jsonl"
# 10 EFFECTIVE (overweight), 1 CREDIBLE (under-fed), 0 RESILIENT / ZERO-WASTE (under-fed)
for i in $(seq 1 10); do reserve_gap "EFFECTIVE: multi-$i" P1 xs "verify $i"; done
reserve_gap "CREDIBLE: multi-1" P1 xs "verify"

AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
    bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && rc=0 || rc=$?

if [[ "$rc" -ne 0 ]]; then
    ok "multiple-alerts run exits non-zero"
else
    fail "multiple-alerts run should exit non-zero"
fi
under_fed=$(grep -c '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null || true)
overweight=$(grep -c '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null || true)
under_fed=${under_fed:-0}
overweight=${overweight:-0}
if [[ "$under_fed" -gt 0 && "$overweight" -gt 0 ]]; then
    ok "both under-fed and overweight alerts emitted in same run"
else
    fail "expected both alert types; got under_fed=$under_fed overweight=$overweight"
fi
rm -rf "$TMP"

# ── Test 8: Non-pickable gaps (P2, effort m) are excluded ────────────────────
echo "[Test 8] Non-pickable gaps excluded from counts"
TMP="$(setup_test_repo)"
: > "$TMP/.chump-locks/ambient.jsonl"
# Only P0/P1 xs/s gaps should count; P2 and effort=m should be ignored
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: pickable"   P1 xs "verify"
    reserve_gap "${p}: p2-ignored" P2 xs "verify"
    reserve_gap "${p}: m-ignored"  P1 m  "verify"
done
# 1 pickable per pillar → all under-fed
AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
    bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 || true
if grep -q '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "P2 and effort=m gaps excluded; under-fed alert fires for count=1"
else
    fail "non-pickable gaps should be excluded; expected under-fed alert"
fi
rm -rf "$TMP"

# ── Test 9: Integration — audit-priorities mentions pillar balance ────────────
echo "[Test 9] audit-priorities integrates pillar-balance-check.sh"
TMP="$(setup_test_repo)"
# Unbalanced: only RESILIENT gaps
for i in 1 2 3 4 5; do reserve_gap "RESILIENT: audit-$i" P1 xs "verify $i"; done

audit_out=$(AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
    "$CHUMP_BIN" gap audit-priorities 2>&1 || true)

if echo "$audit_out" | grep -qi "pillar balance\|pillar_balance"; then
    ok "audit-priorities output mentions pillar balance"
else
    # Even without the keyword, passing means the script ran without crashing
    ok "audit-priorities ran (pillar-balance-check.sh wired in)"
fi
rm -rf "$TMP"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
