#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests pillar-balance-check.sh:
#   AC1: reads state.db via chump gap list --status open
#   AC2: under-fed pillar (< 2) emits kind=pillar_balance_alert with pillar/count/floor=2
#   AC3: overweight pillar (> 50%) emits kind=pillar_balance_overweight with pillar/count/pct
#   AC4: exits non-zero when any alert fired
#   AC5: chump gap audit-priorities calls the script
#   AC6: 8+ tests covering alert schema, thresholds, exit codes

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: Script exists and is executable ──────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable at $SCRIPT"
fi

# ── Resolve chump binary (INFRA-481 shared target-dir + INFRA-902 export) ───
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

if [[ -z "${CHUMP_BIN:-}" || ! -x "$CHUMP_BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
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

# ── Fixture helpers ──────────────────────────────────────────────────────────
_TMPDIRS=()
cleanup_all() { for d in "${_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup_all EXIT

setup_repo() {
    local TMP
    TMP="$(mktemp -d)"
    _TMPDIRS+=("$TMP")
    mkdir -p "$TMP/.chump" "$TMP/.chump-locks" "$TMP/docs/gaps"
    cd "$TMP"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "ci@test.local"
    git config user.name "CI"

    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: disable title-similarity check so 2nd+ fixture gap isn't blocked
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    echo "$TMP"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate 2>/dev/null || true
}

# ── Test 2: Balanced pillars exit 0 ─────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar)"
TMP="$(setup_repo)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
: > "$AMBIENT"

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-a"
    reserve_gap "${p}: balanced-b"
done

if AMBIENT="$AMBIENT" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "balanced pillars exit 0"
else
    fail "balanced pillars should exit 0"
fi

# ── Test 3: Under-fed pillar exits non-zero ──────────────────────────────────
echo "[Test 3] Under-fed pillar (1 RESILIENT) exits non-zero"
TMP="$(setup_repo)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
: > "$AMBIENT"

reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-only"
# ZERO-WASTE intentionally empty (0 gaps)

AMBIENT="$AMBIENT" bash "$SCRIPT" >/dev/null 2>&1 && _rc=0 || _rc=$?
if [[ "$_rc" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi

# ── Test 4: pillar_balance_alert emitted with required fields ────────────────
echo "[Test 4] pillar_balance_alert schema"
if grep -q '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_alert event emitted"
else
    fail "pillar_balance_alert event not found in ambient.jsonl"
fi

if grep '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null \
   | jq -e '.pillar and (.count|type=="number") and .floor' >/dev/null 2>&1; then
    ok "pillar_balance_alert has pillar, count, floor fields"
else
    fail "pillar_balance_alert missing required fields"
fi

if grep '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null \
   | jq -e '.floor == 2' >/dev/null 2>&1; then
    ok "pillar_balance_alert floor == 2"
else
    fail "pillar_balance_alert floor should be 2"
fi

# ── Test 5: Overweight pillar emits pillar_balance_overweight ────────────────
echo "[Test 5] Overweight pillar (EFFECTIVE >50%)"
TMP="$(setup_repo)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
: > "$AMBIENT"

# 6 EFFECTIVE + 1 each of others = 9 total; EFFECTIVE = 67% > 50%
for i in 1 2 3 4 5 6; do reserve_gap "EFFECTIVE: overweight-$i"; done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"

AMBIENT="$AMBIENT" bash "$SCRIPT" >/dev/null 2>&1 && _rc=0 || _rc=$?
if [[ "$_rc" -ne 0 ]]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not found"
fi

if grep '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null \
   | jq -e '.pillar and (.count|type=="number") and (.pct|type=="number")' >/dev/null 2>&1; then
    ok "pillar_balance_overweight has pillar, count, pct fields"
else
    fail "pillar_balance_overweight missing required fields"
fi

if grep '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null \
   | jq -e '.pct > 50' >/dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50"
else
    fail "pillar_balance_overweight pct should be > 50"
fi

# ── Test 6: Non-pickable gaps are excluded ───────────────────────────────────
echo "[Test 6] Non-pickable gaps excluded from counts"
TMP="$(setup_repo)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
: > "$AMBIENT"

# 2 pickable per pillar + various non-pickable
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: pickable-a"
    reserve_gap "${p}: pickable-b"
done
# P2 = not pickable
reserve_gap "EFFECTIVE: p2-gap" P2 xs "check it"
# effort=m = not pickable
reserve_gap "CREDIBLE: medium-gap" P1 m "check it"
# No AC = not pickable (blank ac)
"$CHUMP_BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "RESILIENT: no-ac-gap" --force --force-duplicate 2>/dev/null || true

if AMBIENT="$AMBIENT" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "non-pickable gaps excluded — balanced result still exits 0"
else
    fail "adding non-pickable gaps caused spurious alert"
fi

# ── Test 7: audit-priorities wires pillar-balance-check.sh ──────────────────
echo "[Test 7] chump gap audit-priorities wires pillar-balance (AC5)"
TMP="$(setup_repo)"

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: ap-test-a"
    reserve_gap "${p}: ap-test-b"
done

AP_OUT=$("$CHUMP_BIN" gap audit-priorities 2>&1 || true)
if printf '%s' "$AP_OUT" | grep -qi "pillar"; then
    ok "chump gap audit-priorities output includes pillar balance"
else
    fail "chump gap audit-priorities did not mention pillar — wire missing"
fi

# ── Test 8: Empty state emits alerts for all 4 pillars ──────────────────────
echo "[Test 8] Empty gap store — all 4 pillars under floor"
TMP="$(setup_repo)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
: > "$AMBIENT"

# No gaps at all
AMBIENT="$AMBIENT" bash "$SCRIPT" >/dev/null 2>&1 && _rc=0 || _rc=$?
if [[ "$_rc" -ne 0 ]]; then
    ok "empty store exits non-zero"
else
    fail "empty store should exit non-zero"
fi

_alert_count=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null || echo 0)
if [[ "${_alert_count:-0}" -ge 4 ]]; then
    ok "empty store emits alert for all 4 pillars ($_alert_count alerts)"
else
    fail "empty store should emit 4 alerts, got ${_alert_count:-0}"
fi

# ── Test 9: Ambient file path created if .chump-locks/ missing ───────────────
echo "[Test 9] mkdir -p for ambient path"
TMP="$(setup_repo)"
rm -rf "$TMP/.chump-locks"
NEW_AMBIENT="$TMP/.chump-locks/ambient.jsonl"

reserve_gap "EFFECTIVE: mkdir-test-a"
reserve_gap "EFFECTIVE: mkdir-test-b"
reserve_gap "CREDIBLE: mkdir-test-a"
reserve_gap "CREDIBLE: mkdir-test-b"
reserve_gap "RESILIENT: mkdir-test-a"
reserve_gap "RESILIENT: mkdir-test-b"
reserve_gap "ZERO-WASTE: mkdir-test-a"
reserve_gap "ZERO-WASTE: mkdir-test-b"

# Should not fail even if .chump-locks/ doesn't exist yet
AMBIENT="$NEW_AMBIENT" bash "$SCRIPT" >/dev/null 2>&1 && _rc=0 || _rc=$?
if [[ -d "$TMP/.chump-locks" ]]; then
    ok "mkdir -p created .chump-locks/ directory"
else
    fail ".chump-locks/ directory was not created"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
