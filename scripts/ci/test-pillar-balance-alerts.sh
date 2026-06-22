#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests scripts/ops/pillar-balance-check.sh.
# AC1: script reads state.db via 'chump gap list --status open'
# AC2: pillar count < 2 → emits kind=pillar_balance_alert (pillar, count, floor=2)
# AC3: pillar count > 50% of total → emits kind=pillar_balance_overweight (pillar, count, pct)
# AC4: script exits non-zero when any alert fired
# AC5: chump gap audit-priorities calls pillar-balance-check.sh
# AC6: 8+ tests

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve chump binary robustly: honor shared target-dir per INFRA-481.
# cargo metadata target_directory points to the real target, which may be
# outside the worktree root when .cargo/config.toml overrides it.
# Export CHUMP_BIN so pillar-balance-check.sh uses the same fixture binary.
_cargo_tgt=""
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

# ── Test 1: script exists and is executable ──────────────────────────────────
if [[ -x "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture helpers ──────────────────────────────────────────────────────────
setup_test_repo() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump" "$tmp/docs/gaps" "$tmp/.chump-locks"

    cd "$tmp"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git config user.email "test@ci.local" 2>/dev/null || true
    git config user.name "CI"            2>/dev/null || true

    export CHUMP_REPO="$tmp"
    export CHUMP_WORKTREE_ROOT="$tmp"
    export CHUMP_HOME="$tmp"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # INFRA-1149: title-similarity check blocks 2nd+ fixture gap by default.
    # Disable it so pillar counts actually populate.
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

    printf '%s' "$tmp"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve \
        --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" \
        --force --force-duplicate 2>/dev/null || true
}

FIRST_TMP=""

# ── Test 2: balanced pillars exit 0 ─────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar)"
TMP2="$(setup_test_repo)"
FIRST_TMP="$TMP2"
trap 'rm -rf "$FIRST_TMP"' EXIT

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

rm -rf "$TMP2"

# ── Test 3: under-fed pillar (<2) emits alert + exits non-zero ──────────────
echo "[Test 3] Under-fed pillar alert"
TMP3="$(setup_test_repo)"
trap 'rm -rf "$TMP3"' EXIT

reserve_gap "EFFECTIVE: under-a"
reserve_gap "EFFECTIVE: under-b"
reserve_gap "CREDIBLE: under-a"
reserve_gap "CREDIBLE: under-b"
reserve_gap "RESILIENT: under-a"   # only 1 RESILIENT → alert; ZERO-WASTE=0 → alert
: > "$TMP3/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && exit_code=0 || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero"
else
    fail "under-fed pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_alert event emitted"
else
    fail "pillar_balance_alert event not found in ambient.jsonl"
fi

if grep '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" \
   | jq -e '.pillar and (.count != null) and .floor' >/dev/null 2>&1; then
    ok "pillar_balance_alert has required fields (pillar, count, floor)"
else
    fail "pillar_balance_alert missing required fields"
fi

if grep '"kind":"pillar_balance_alert"' "$TMP3/.chump-locks/ambient.jsonl" \
   | jq -e '.floor == 2' >/dev/null 2>&1; then
    ok "pillar_balance_alert floor == 2"
else
    fail "pillar_balance_alert floor should be 2"
fi

rm -rf "$TMP3"

# ── Test 4: overweight pillar (>50%) emits alert ────────────────────────────
echo "[Test 4] Overweight pillar alert"
TMP4="$(setup_test_repo)"
trap 'rm -rf "$TMP4"' EXIT

# 6 EFFECTIVE + 1 each of the rest → EFFECTIVE = 6/9 = 67 % > 50 %
for i in $(seq 1 6); do reserve_gap "EFFECTIVE: overweight-$i"; done
reserve_gap "CREDIBLE: overweight-1"
reserve_gap "RESILIENT: overweight-1"
reserve_gap "ZERO-WASTE: overweight-1"
: > "$TMP4/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && exit_code=0 || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    ok "overweight pillar exits non-zero"
else
    fail "overweight pillar should exit non-zero"
fi

if grep -q '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted"
else
    fail "pillar_balance_overweight event not found"
fi

if grep '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" \
   | jq -e '.pillar and (.count != null) and .pct' >/dev/null 2>&1; then
    ok "pillar_balance_overweight has required fields (pillar, count, pct)"
else
    fail "pillar_balance_overweight missing required fields"
fi

if grep '"kind":"pillar_balance_overweight"' "$TMP4/.chump-locks/ambient.jsonl" \
   | jq -e '.pct > 50' >/dev/null 2>&1; then
    ok "pillar_balance_overweight pct > 50"
else
    fail "pillar_balance_overweight pct should be > 50"
fi

rm -rf "$TMP4"

# ── Test 5: TODO ACs are excluded from pickable count ───────────────────────
echo "[Test 5] Non-pickable gaps (TODO AC) are excluded"
TMP5="$(setup_test_repo)"
trap 'rm -rf "$TMP5"' EXIT

# 1 real pickable EFFECTIVE + 1 TODO-AC EFFECTIVE (should not count)
reserve_gap "EFFECTIVE: real-pickable" P1 xs "verify it works"
reserve_gap "CREDIBLE: todo-ac" P1 xs "TODO"
: > "$TMP5/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 || true

# CREDIBLE has TODO AC → not pickable → CREDIBLE count=0 → alert fired
if grep -q '"kind":"pillar_balance_alert"' "$TMP5/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "TODO-AC gap excluded from pickable count (alert fired for starved pillar)"
else
    fail "TODO-AC gap should be excluded; pillar should be starved"
fi

rm -rf "$TMP5"

# ── Test 6: healthy state produces no alerts ─────────────────────────────────
echo "[Test 6] Healthy state produces no alerts"
TMP6="$(setup_test_repo)"
trap 'rm -rf "$TMP6"' EXIT

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: healthy-1" P1 xs "ac1"
    reserve_gap "${p}: healthy-2" P1 xs "ac2"
    reserve_gap "${p}: healthy-3" P1 xs "ac3"
done
: > "$TMP6/.chump-locks/ambient.jsonl"

if bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1; then
    ok "healthy state exits 0"
else
    fail "healthy state should exit 0"
fi

# ambient.jsonl should be empty (no alerts) — use grep -c + ${var:-0} pattern
alert_count=$(grep -c '"kind":"pillar_balance' "$TMP6/.chump-locks/ambient.jsonl" 2>/dev/null || true)
alert_count=${alert_count:-0}
if [[ "$alert_count" -eq 0 ]]; then
    ok "healthy state produces no ambient alerts"
else
    fail "healthy state should produce no alerts (got $alert_count)"
fi

rm -rf "$TMP6"

# ── Test 7: audit-priorities calls pillar-balance-check.sh ──────────────────
echo "[Test 7] audit-priorities calls pillar-balance-check.sh"
TMP7="$(setup_test_repo)"
trap 'rm -rf "$TMP7"' EXIT

for i in $(seq 1 5); do
    reserve_gap "RESILIENT: audit-test-$i" P1 xs "verify $i"
done

audit_output=$("$CHUMP_BIN" gap audit-priorities 2>&1 || true)

if echo "$audit_output" | grep -qi "pillar balance"; then
    ok "audit-priorities output mentions pillar balance"
else
    fail "audit-priorities should mention pillar balance (got: $audit_output)"
fi

rm -rf "$TMP7"

# ── Test 8: both under-fed and overweight alerts in one run ─────────────────
echo "[Test 8] Multiple alert types in single run"
TMP8="$(setup_test_repo)"
trap 'rm -rf "$TMP8"' EXIT

# 10 EFFECTIVE (>50%), 1 CREDIBLE, 0 RESILIENT, 0 ZERO-WASTE
for i in $(seq 1 10); do reserve_gap "EFFECTIVE: multi-$i" P1 xs "verify $i"; done
reserve_gap "CREDIBLE: multi-1" P1 xs "verify"
: > "$TMP8/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && exit_code=0 || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    ok "multiple-alert scenario exits non-zero"
else
    fail "multiple-alert scenario should exit non-zero"
fi

# grep -c on no-match exits 1 and prints "0"; use || true + ${var:-0} to avoid
# the pipeline aborting under set -e.
under_fed=$(grep -c '"kind":"pillar_balance_alert"' "$TMP8/.chump-locks/ambient.jsonl" \
    2>/dev/null || true)
under_fed=${under_fed:-0}
overweight=$(grep -c '"kind":"pillar_balance_overweight"' "$TMP8/.chump-locks/ambient.jsonl" \
    2>/dev/null || true)
overweight=${overweight:-0}

if [[ "$under_fed" -gt 0 && "$overweight" -gt 0 ]]; then
    ok "both under-fed and overweight alerts emitted"
else
    fail "should emit both alert types (under_fed=$under_fed overweight=$overweight)"
fi

rm -rf "$TMP8"

# ── Test 9: P2 and m-effort gaps are excluded from pickable count ────────────
echo "[Test 9] P2 and m-effort gaps excluded"
TMP9="$(setup_test_repo)"
trap 'rm -rf "$TMP9"' EXIT

# Only non-pickable gaps in EFFECTIVE (P2 + m-effort) → should not reach floor of 2
reserve_gap "EFFECTIVE: p2-gap" P2 xs "verify it"
reserve_gap "EFFECTIVE: m-gap"  P1 m  "verify it"
# Give other pillars 2 each to isolate the EFFECTIVE exclusion
for p in CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: nonpick-test-a" P1 xs "ac"
    reserve_gap "${p}: nonpick-test-b" P1 xs "ac"
done
: > "$TMP9/.chump-locks/ambient.jsonl"

bash "$REPO_ROOT/scripts/ops/pillar-balance-check.sh" >/dev/null 2>&1 \
    && exit_code=0 || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    ok "P2/m-effort gaps excluded — EFFECTIVE starved → alert"
else
    fail "EFFECTIVE with only P2/m gaps should trigger under-fed alert"
fi

effective_alert=$(grep '"kind":"pillar_balance_alert"' "$TMP9/.chump-locks/ambient.jsonl" \
    2>/dev/null | jq -r '.pillar' | grep -c EFFECTIVE || true)
effective_alert=${effective_alert:-0}
if [[ "$effective_alert" -gt 0 ]]; then
    ok "pillar_balance_alert emitted for EFFECTIVE specifically"
else
    fail "pillar_balance_alert should target EFFECTIVE"
fi

rm -rf "$TMP9"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
