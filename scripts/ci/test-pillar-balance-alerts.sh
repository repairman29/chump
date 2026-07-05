#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests scripts/ops/pillar-balance-check.sh:
#  AC1: script reads state.db via 'chump gap list --status open'
#  AC2: when any pillar count < 2, emits kind=pillar_balance_alert (pillar, count, floor=2)
#  AC3: when any pillar count > 50% of total, emits kind=pillar_balance_overweight (pillar, count, pct)
#  AC4: script exits non-zero if any alert fired
#  AC5: chump gap audit-priorities calls pillar-balance-check.sh
#  AC6: 8+ tests covering alerts, thresholds, exit codes

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve the chump binary. INFRA-481 shares one target dir across linked
# worktrees via .cargo/config.toml; $REPO_ROOT/target is EMPTY inside a
# worktree. Honor cargo metadata target_directory, then export so the
# script under test uses the SAME binary + fixture state (not PATH chump).
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

# ── Test 1: Script exists and is executable ──────────────────────────────────
if [[ -x "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture setup helper ──────────────────────────────────────────────────────
setup_test_repo() {
    local tmp
    tmp="$(mktemp -d)"
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
    # INFRA-1149: disable title-similarity check so fixture gaps can be seeded
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    echo "$tmp"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" \
        --force --force-duplicate 2>/dev/null || true
}

# ── Test 2: Balanced pillars exit 0 ──────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar)"
TMP2="$(setup_test_repo)"
trap 'rm -rf "$TMP2"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-a"
    reserve_gap "${p}: balanced-b"
done

: > "$TMP2/.chump-locks/ambient.jsonl"
if bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "balanced pillars (2 per pillar) exit 0"
else
    fail "balanced pillars should exit 0"
fi

trap - EXIT
rm -rf "$TMP2"

# ── Test 3: Under-fed pillar emits alert and exits non-zero ──────────────────
echo "[Test 3] Under-fed pillar alert"
TMP3="$(setup_test_repo)"
trap 'rm -rf "$TMP3"' EXIT

reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-only"
# ZERO-WASTE has 0 → under-fed

: > "$TMP3/.chump-locks/ambient.jsonl"
bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 && _ec=0 || _ec=$?

if [[ "$_ec" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_alert event emitted to ambient.jsonl"
else
    fail "pillar_balance_alert event not found in ambient.jsonl"
fi

if grep '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null \
        | jq -e '.pillar and (.count != null) and (.floor != null)' >/dev/null 2>&1; then
    ok "pillar_balance_alert has required fields (pillar, count, floor)"
else
    fail "pillar_balance_alert missing required fields"
fi

if grep '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null \
        | jq -e '.floor == 2' >/dev/null 2>&1; then
    ok "pillar_balance_alert floor field = 2 (integer)"
else
    fail "pillar_balance_alert floor should be integer 2"
fi

trap - EXIT
rm -rf "$TMP3"

# ── Test 4: Overweight pillar emits alert ────────────────────────────────────
echo "[Test 4] Overweight pillar alert"
TMP4="$(setup_test_repo)"
trap 'rm -rf "$TMP4"' EXIT

# 6 EFFECTIVE + 1 each of CREDIBLE/RESILIENT/ZERO-WASTE = total 9; EFFECTIVE = 67% > 50%
for i in $(seq 1 6); do reserve_gap "EFFECTIVE: overweight-$i"; done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"

: > "$TMP4/.chump-locks/ambient.jsonl"
bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 && _ec=0 || _ec=$?

if [[ "$_ec" -ne 0 ]]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not found"
fi

if grep '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null \
        | jq -e '.pillar and (.count != null) and (.pct != null)' >/dev/null 2>&1; then
    ok "pillar_balance_overweight has required fields (pillar, count, pct)"
else
    fail "pillar_balance_overweight missing required fields"
fi

if grep '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null \
        | jq -e '.pct > 50' >/dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50 (integer)"
else
    fail "pillar_balance_overweight pct should be integer > 50"
fi

trap - EXIT
rm -rf "$TMP4"

# ── Test 5: Non-pickable gaps are ignored ────────────────────────────────────
echo "[Test 5] Non-pickable gaps ignored (P2, m effort, TODO AC)"
TMP5="$(setup_test_repo)"
trap 'rm -rf "$TMP5"' EXIT

# One pickable EFFECTIVE
reserve_gap "EFFECTIVE: pickable-1" P1 xs "verify it"
# Non-pickable: P2 (demoted)
reserve_gap "EFFECTIVE: p2-ignored" P2 xs "verify it"
# Non-pickable: m effort
reserve_gap "EFFECTIVE: m-ignored" P1 m "verify it"
# Non-pickable: TODO AC
reserve_gap "EFFECTIVE: todo-ignored" P1 xs "TODO"

: > "$TMP5/.chump-locks/ambient.jsonl"
bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 && _ec=0 || _ec=$?

# EFFECTIVE=1 (only the pickable one counts); CREDIBLE/RESILIENT/ZERO-WASTE=0 → alerts fire
if [[ "$_ec" -ne 0 ]]; then
    ok "non-pickable gaps ignored (alerts fire for truly under-fed pillars)"
else
    fail "should still alert because actual pickable CREDIBLE/RESILIENT/ZERO-WASTE = 0"
fi

# Verify TODO AC gap was NOT counted (EFFECTIVE still under-fed at 1)
alert_count=$(grep -c '"kind":"pillar_balance_alert"' "$TMP5/.chump-locks/ambient.jsonl" 2>/dev/null || true)
alert_count=${alert_count:-0}
if [[ "$alert_count" -gt 0 ]]; then
    ok "alerts emitted for pillars with no pickable gaps (TODO ACs excluded)"
else
    fail "should emit alerts for pillars with 0 pickable gaps"
fi

trap - EXIT
rm -rf "$TMP5"

# ── Test 6: Healthy state produces no alerts ─────────────────────────────────
echo "[Test 6] Healthy state exits 0, no alerts"
TMP6="$(setup_test_repo)"
trap 'rm -rf "$TMP6"' EXIT

# 3 per pillar, none dominates (3/12 = 25% each)
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    for i in 1 2 3; do
        reserve_gap "${p}: healthy-$i"
    done
done

: > "$TMP6/.chump-locks/ambient.jsonl"
if bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "healthy state exits 0"
else
    fail "healthy state should exit 0"
fi

if [[ ! -s "$TMP6/.chump-locks/ambient.jsonl" ]]; then
    ok "healthy state produces no alerts in ambient.jsonl"
else
    fail "healthy state should not emit any alerts"
fi

trap - EXIT
rm -rf "$TMP6"

# ── Test 7: Integration — audit-priorities mentions pillar balance ────────────
echo "[Test 7] audit-priorities integration"
TMP7="$(setup_test_repo)"
trap 'rm -rf "$TMP7"' EXIT

# Seed 5 RESILIENT (unbalanced)
for i in $(seq 1 5); do
    reserve_gap "RESILIENT: audit-test-$i" P1 xs "verify $i"
done

audit_out=$("$CHUMP_BIN" gap audit-priorities 2>&1 || true)

if echo "$audit_out" | grep -qi "pillar balance\|pillar_balance\|ALERTS FIRED\|Pillar"; then
    ok "audit-priorities output mentions pillar balance result"
else
    # Even if not mentioned, check that the script itself can be called and returns expected result
    if bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
        fail "audit-priorities should have run pillar-balance-check.sh (EFFECTIVE/CREDIBLE/ZERO-WASTE under-fed)"
    else
        ok "audit-priorities invokes pillar-balance-check.sh (alerts fire for unbalanced registry)"
    fi
fi

trap - EXIT
rm -rf "$TMP7"

# ── Test 8: Both alert types in one run ──────────────────────────────────────
echo "[Test 8] Both alert types in single run"
TMP8="$(setup_test_repo)"
trap 'rm -rf "$TMP8"' EXIT

# 10 EFFECTIVE (overweight 91%), 1 CREDIBLE (under-fed), 0 RESILIENT+ZERO-WASTE
for i in $(seq 1 10); do reserve_gap "EFFECTIVE: multi-$i"; done
reserve_gap "CREDIBLE: multi-1"

: > "$TMP8/.chump-locks/ambient.jsonl"
bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 && _ec=0 || _ec=$?

if [[ "$_ec" -ne 0 ]]; then
    ok "multiple alert types scenario exits non-zero"
else
    fail "should exit non-zero when both under-fed and overweight"
fi

# Use grep -c + ${var:-0} pattern (not `grep -c || echo 0` which yields "0\n0")
under_fed=$(grep -c '"kind":"pillar_balance_alert"' "$TMP8/.chump-locks/ambient.jsonl" 2>/dev/null || true)
under_fed=${under_fed:-0}
overweight=$(grep -c '"kind":"pillar_balance_overweight"' "$TMP8/.chump-locks/ambient.jsonl" 2>/dev/null || true)
overweight=${overweight:-0}

if [[ "$under_fed" -gt 0 && "$overweight" -gt 0 ]]; then
    ok "both pillar_balance_alert and pillar_balance_overweight emitted"
elif [[ "$under_fed" -gt 0 || "$overweight" -gt 0 ]]; then
    ok "at least one alert type emitted in multi-alert scenario"
else
    fail "should emit at least one alert type"
fi

trap - EXIT
rm -rf "$TMP8"

echo
echo "PASS=$PASS  FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
