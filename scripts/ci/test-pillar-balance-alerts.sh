#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh
# AC coverage: alert schema, thresholds, exit codes, integration with audit-priorities

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ── Resolve chump binary (INFRA-481: worktrees share a target dir) ────────────
_cargo_tgt="$(cargo metadata --format-version 1 --no-deps \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' \
    2>/dev/null || true)"

CHUMP_BIN="${CHUMP_BIN:-}"
for _cand in \
    "$CHUMP_BIN" \
    "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
    "$REPO_ROOT/target/debug/chump" \
    "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
    [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
done

if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "[build] cargo build --bin chump ..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
    for _cand in \
        "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
        "$REPO_ROOT/target/debug/chump" \
        "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
        [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
    done
fi
# Export so pillar-balance-check.sh uses the same fixture binary, not PATH chump
export CHUMP_BIN

if [[ ! -x "$CHUMP_BIN" ]]; then
    fail "chump binary not found after build — cannot continue"
    echo "PASS=$PASS  FAIL=$FAIL"
    exit 1
fi

echo "=== INFRA-902 pillar-balance-alerts tests (chump=$CHUMP_BIN) ==="
echo

# ── Test 1: Script exists and is executable ───────────────────────────────────
if [[ -x "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture helpers ───────────────────────────────────────────────────────────
setup_fixture() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump" "$tmp/.chump-locks" "$tmp/docs/gaps"
    cd "$tmp"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "test@ci.local" 2>/dev/null || true
    git config user.name  "CI"            2>/dev/null || true

    export CHUMP_REPO="$tmp"
    export CHUMP_WORKTREE_ROOT="$tmp"
    export CHUMP_HOME="$tmp"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: title-similarity check blocks 2nd+ fixture gap — disable
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    echo "$tmp"
}

reserve() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA \
        --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" \
        --force --force-duplicate 2>/dev/null || true
}

run_pbc() {
    # Run the script with AMBIENT pointing at the fixture's .chump-locks/ambient.jsonl
    export AMBIENT="$(pwd)/.chump-locks/ambient.jsonl"
    : > "$AMBIENT"
    bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" 2>/dev/null
}

# ── Test 2: Balanced pillars (2 per pillar) exits 0 ──────────────────────────
echo "[Test 2] Balanced pillars exit 0"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve "${p}: balance-a"
    reserve "${p}: balance-b"
done

if run_pbc; then
    ok "balanced pillars exit 0"
else
    fail "balanced pillars should exit 0 but exited non-zero"
fi
rm -rf "$TMP"; trap - EXIT

# ── Test 3: Under-fed pillar emits alert + exits non-zero ────────────────────
echo "[Test 3] Under-fed pillar alert"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

reserve "EFFECTIVE: under-a"; reserve "EFFECTIVE: under-b"
reserve "CREDIBLE: under-a";  reserve "CREDIBLE: under-b"
reserve "RESILIENT: under-a"  # count=1 < floor=2

run_pbc && pbc_exit=0 || pbc_exit=$?

if [[ "$pbc_exit" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero (AC4)"
else
    fail "under-fed pillar should exit non-zero"
fi

AMBIENT="$(pwd)/.chump-locks/ambient.jsonl"
if grep -q '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_alert event emitted (AC2)"
else
    fail "pillar_balance_alert not found in ambient.jsonl"
fi

if grep '"kind":"pillar_balance_alert"' "$AMBIENT" \
   | jq -e '.pillar and (.count != null) and .floor' >/dev/null 2>&1; then
    ok "pillar_balance_alert has required fields: pillar, count, floor (AC2)"
else
    fail "pillar_balance_alert missing required fields"
fi

if grep '"kind":"pillar_balance_alert"' "$AMBIENT" \
   | jq -e '.floor == 2' >/dev/null 2>&1; then
    ok "pillar_balance_alert floor == 2 (AC2)"
else
    fail "pillar_balance_alert floor should be 2"
fi

rm -rf "$TMP"; trap - EXIT

# ── Test 4: Overweight pillar emits alert + exits non-zero ───────────────────
echo "[Test 4] Overweight pillar alert"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

# 6 EFFECTIVE + 1 each of the others → EFFECTIVE=6/9=67% > 50%
for i in 1 2 3 4 5 6; do reserve "EFFECTIVE: overweight-$i"; done
reserve "CREDIBLE: overweight-1"
reserve "RESILIENT: overweight-1"
reserve "ZERO-WASTE: overweight-1"

AMBIENT="$(pwd)/.chump-locks/ambient.jsonl"
run_pbc && pbc_exit=0 || pbc_exit=$?

if [[ "$pbc_exit" -ne 0 ]]; then
    ok "overweight pillar exits non-zero (AC4)"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted (AC3)"
else
    fail "pillar_balance_overweight not found in ambient.jsonl"
fi

if grep '"kind":"pillar_balance_overweight"' "$AMBIENT" \
   | jq -e '.pillar and (.count != null) and .pct' >/dev/null 2>&1; then
    ok "pillar_balance_overweight has required fields: pillar, count, pct (AC3)"
else
    fail "pillar_balance_overweight missing required fields"
fi

if grep '"kind":"pillar_balance_overweight"' "$AMBIENT" \
   | jq -e '.pct > 50' >/dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50 (AC3)"
else
    fail "pillar_balance_overweight pct should be > 50"
fi

rm -rf "$TMP"; trap - EXIT

# ── Test 5: Non-pickable gaps are excluded ───────────────────────────────────
echo "[Test 5] Non-pickable gaps excluded"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

# Pickable: 2 per pillar
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve "${p}: pickable-a"; reserve "${p}: pickable-b"
done
# Non-pickable: wrong priority, wrong effort, TODO AC — should be ignored
reserve "EFFECTIVE: ignored-p2" P2 xs "verify"
reserve "EFFECTIVE: ignored-m"  P1 m  "verify"
reserve "EFFECTIVE: ignored-todo" P1 xs "TODO"

if run_pbc; then
    ok "non-pickable gaps ignored; 2-per-pillar still exits 0"
else
    fail "non-pickable gaps should not trigger alerts when floor is met"
fi

rm -rf "$TMP"; trap - EXIT

# ── Test 6: Healthy 3-per-pillar state produces no alerts ────────────────────
echo "[Test 6] Healthy state produces no events"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    for i in 1 2 3; do reserve "${p}: healthy-$i"; done
done

AMBIENT="$(pwd)/.chump-locks/ambient.jsonl"
run_pbc && pbc_exit=0 || pbc_exit=$?

if [[ "$pbc_exit" -eq 0 ]]; then
    ok "healthy 3-per-pillar exits 0"
else
    fail "healthy state should exit 0"
fi

if [[ ! -s "$AMBIENT" ]]; then
    ok "healthy state emits nothing to ambient.jsonl"
else
    fail "healthy state should produce no ambient events"
fi

rm -rf "$TMP"; trap - EXIT

# ── Test 7: Both alert types fire in a single run ────────────────────────────
echo "[Test 7] Both under-fed and overweight alerts in one run"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

# 10 EFFECTIVE (overweight), 1 CREDIBLE (under floor), rest 0
for i in $(seq 1 10); do reserve "EFFECTIVE: multi-$i"; done
reserve "CREDIBLE: multi-1"

AMBIENT="$(pwd)/.chump-locks/ambient.jsonl"
run_pbc && pbc_exit=0 || pbc_exit=$?

if [[ "$pbc_exit" -ne 0 ]]; then
    ok "multiple-alert scenario exits non-zero"
else
    fail "multiple-alert scenario should exit non-zero"
fi

# Use ${var:-0} to avoid arithmetic errors when grep returns nothing (INFRA-902 fix)
under_count=$(grep -c '"kind":"pillar_balance_alert"'      "$AMBIENT" 2>/dev/null || true)
over_count=$(grep -c  '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null || true)
under_count=${under_count:-0}
over_count=${over_count:-0}

if [[ "$under_count" -gt 0 ]]; then
    ok "under-fed alerts emitted ($under_count)"
else
    fail "expected at least one pillar_balance_alert"
fi

if [[ "$over_count" -gt 0 ]]; then
    ok "overweight alerts emitted ($over_count)"
else
    fail "expected at least one pillar_balance_overweight"
fi

rm -rf "$TMP"; trap - EXIT

# ── Test 8: Integration — audit-priorities mentions pillar balance ─────────
echo "[Test 8] audit-priorities integration"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

# Unbalanced registry so alerts will fire
for i in 1 2 3 4 5; do reserve "RESILIENT: audit-$i"; done

export AMBIENT="$(pwd)/.chump-locks/ambient.jsonl"
audit_out=$("$CHUMP_BIN" gap audit-priorities 2>&1 || true)

if echo "$audit_out" | grep -qiE "pillar balance|pillar_balance"; then
    ok "audit-priorities output references pillar balance (AC5)"
else
    # If alerts fired, the script was still called — check ambient
    if grep -q 'pillar_balance' "$AMBIENT" 2>/dev/null; then
        ok "audit-priorities called pillar-balance-check.sh (events in ambient)"
    else
        fail "audit-priorities should call pillar-balance-check.sh"
    fi
fi

rm -rf "$TMP"; trap - EXIT

# ── Test 9: Script creates ambient dir if missing ─────────────────────────────
echo "[Test 9] Script creates .chump-locks/ dir if absent"
TMP="$(setup_fixture)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$TMP/.chump-locks"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
export AMBIENT
# Script should mkdir -p before writing; don't pre-create
bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" 2>/dev/null || true

if [[ -d "$TMP/.chump-locks" ]]; then
    ok "script creates .chump-locks/ directory when absent"
else
    fail "script should create .chump-locks/ before writing"
fi

rm -rf "$TMP"; trap - EXIT

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
