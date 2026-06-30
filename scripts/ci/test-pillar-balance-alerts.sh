#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests pillar-balance-check.sh alert logic:
#  AC1: script reads state.db via chump gap list --status open
#  AC2: under-fed pillar (< 2) emits kind=pillar_balance_alert with pillar, count, floor=2
#  AC3: overweight pillar (> 50%) emits kind=pillar_balance_overweight with pillar, count, pct
#  AC4: script exits non-zero if any alert fired
#  AC5: chump gap audit-priorities calls the script and includes result
#  AC6: 8+ tests verifying alert schema, thresholds, exit codes

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

# ── Resolve chump binary (INFRA-481: shared target-dir via .cargo/config.toml) ─
# Worktrees have an empty $REPO_ROOT/target — honor cargo metadata's target_directory.
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
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    for _cand in \
        "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/debug/chump}" \
        "$REPO_ROOT/target/debug/chump" \
        "${_cargo_tgt:+$_cargo_tgt/debug/chump}"; do
        [[ -n "$_cand" && -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
    done
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FATAL: chump binary not found after build" >&2
    exit 2
fi
# Export so pillar-balance-check.sh uses the same fixture binary, not PATH chump
export CHUMP_BIN

echo "=== INFRA-902 pillar-balance-alerts tests (using $CHUMP_BIN) ==="
echo

# ── Fixture helpers ───────────────────────────────────────────────────────────

setup_repo() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump" "$tmp/docs/gaps" "$tmp/.chump-locks"
    (
        cd "$tmp"
        git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
        git config user.email "test@ci.local" 2>/dev/null || true
        git config user.name "CI" 2>/dev/null || true
    )
    echo "$tmp"
}

reserve_gap() {
    # $1=title $2=priority(P1) $3=effort(xs) $4=ac
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --priority "$priority" \
        --effort "$effort" \
        --title "$title" \
        --acceptance-criteria "$ac" \
        --force \
        --force-duplicate 2>/dev/null || true
}

run_check() {
    # Run pillar-balance-check.sh with the current CHUMP_REPO set.
    # Redirects AMBIENT to a known path in the tmp dir.
    AMBIENT="${CHUMP_REPO}/.chump-locks/ambient.jsonl" \
        bash "$SCRIPT" >/dev/null 2>&1
}

# ── Test 1: Script exists and is executable ───────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Test 2: Balanced pillars exit 0 ──────────────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar) → exit 0"
TMP="$(setup_repo)"
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1   # INFRA-1149 guard
    cd "$TMP"
    for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
        reserve_gap "${p}: bal-a"
        reserve_gap "${p}: bal-b"
    done
    AMBIENT="$TMP/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1
) && ok "balanced pillars (2 per pillar) exits 0" \
  || fail "balanced pillars should exit 0"
rm -rf "$TMP"

# ── Test 3: Under-fed pillar exits non-zero + emits alert ────────────────────
echo "[Test 3] Under-fed pillar (RESILIENT=1) → exit 1 + pillar_balance_alert"
TMP="$(setup_repo)"
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    cd "$TMP"
    reserve_gap "EFFECTIVE: under-a"
    reserve_gap "EFFECTIVE: under-b"
    reserve_gap "CREDIBLE: under-a"
    reserve_gap "CREDIBLE: under-b"
    reserve_gap "RESILIENT: under-a"   # only 1 — under floor
    : > "$TMP/.chump-locks/ambient.jsonl"
    AMBIENT="$TMP/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1
    exit $?
) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "under-fed pillar exits non-zero (AC4)"
else
    fail "under-fed pillar should exit non-zero"
fi

# Check alert was emitted
if grep -q '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_alert event emitted to ambient.jsonl (AC2)"
else
    fail "pillar_balance_alert event missing from ambient.jsonl"
fi

# Verify required fields: pillar, count, floor=2
if jq -e '.kind == "pillar_balance_alert" and .pillar and (.count >= 0) and .floor == 2' \
       "$TMP/.chump-locks/ambient.jsonl" >/dev/null 2>&1; then
    ok "pillar_balance_alert has pillar, count, floor=2 (AC2 schema)"
else
    fail "pillar_balance_alert missing required fields or floor != 2"
fi
rm -rf "$TMP"

# ── Test 4: Overweight pillar emits pillar_balance_overweight ────────────────
echo "[Test 4] Overweight pillar (EFFECTIVE=6 of 9 total = 67%) → overweight alert"
TMP="$(setup_repo)"
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    cd "$TMP"
    for i in $(seq 1 6); do reserve_gap "EFFECTIVE: heavy-$i"; done
    reserve_gap "CREDIBLE: ow-1"
    reserve_gap "RESILIENT: ow-1"
    reserve_gap "ZERO-WASTE: ow-1"
    : > "$TMP/.chump-locks/ambient.jsonl"
    AMBIENT="$TMP/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1
    exit $?
) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "overweight pillar exits non-zero (AC4)"
else
    fail "overweight pillar should exit non-zero"
fi
if grep -q '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pillar_balance_overweight event emitted (AC3)"
else
    fail "pillar_balance_overweight event missing"
fi
# Verify schema: pillar, count, pct > 50
if jq -e '.kind == "pillar_balance_overweight" and .pillar and .count and (.pct > 50)' \
       "$TMP/.chump-locks/ambient.jsonl" >/dev/null 2>&1; then
    ok "pillar_balance_overweight has pillar, count, pct>50 (AC3 schema)"
else
    fail "pillar_balance_overweight missing required fields or pct <= 50"
fi
rm -rf "$TMP"

# ── Test 5: Non-pickable gaps are excluded ────────────────────────────────────
echo "[Test 5] Non-pickable gaps (P2, m effort, TODO AC) are excluded from counts"
TMP="$(setup_repo)"
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    cd "$TMP"
    # 2 pickable EFFECTIVE
    reserve_gap "EFFECTIVE: pick-a" P1 xs "verify a"
    reserve_gap "EFFECTIVE: pick-b" P1 xs "verify b"
    # Non-pickable: P2
    reserve_gap "CREDIBLE: p2-skip" P2 xs "verify"
    # Non-pickable: m effort
    reserve_gap "RESILIENT: m-skip" P1 m "verify"
    # Non-pickable: TODO AC
    reserve_gap "ZERO-WASTE: todo-skip" P1 xs "TODO"
    : > "$TMP/.chump-locks/ambient.jsonl"
    AMBIENT="$TMP/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1
    exit $?
) && rc=0 || rc=$?
# With only EFFECTIVE=2, CREDIBLE/RESILIENT/ZERO-WASTE=0 (non-pickable excluded),
# we expect under-fed alerts for the three empty pillars.
if [[ "$rc" -ne 0 ]]; then
    ok "non-pickable gaps excluded — 3 empty pillars trigger exit non-zero"
else
    fail "should exit non-zero when three pillars have 0 pickable after exclusions"
fi
# Verify no pillar_balance_alert fired for EFFECTIVE (it has 2, at floor)
if grep '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null \
    | grep -q '"pillar":"EFFECTIVE"'; then
    fail "EFFECTIVE (count=2) should NOT trigger under-fed alert"
else
    ok "EFFECTIVE (count=2) correctly not flagged as under-fed"
fi
rm -rf "$TMP"

# ── Test 6: Healthy state produces zero events ────────────────────────────────
echo "[Test 6] Healthy state (3 per pillar, balanced) → exit 0, no events"
TMP="$(setup_repo)"
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    cd "$TMP"
    for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
        for i in 1 2 3; do reserve_gap "${p}: h-$i"; done
    done
    : > "$TMP/.chump-locks/ambient.jsonl"
    AMBIENT="$TMP/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1
) && ok "healthy state exits 0" \
  || fail "healthy state should exit 0"
if [[ ! -s "$TMP/.chump-locks/ambient.jsonl" ]]; then
    ok "healthy state emits no events"
else
    fail "healthy state should emit no events; got: $(cat "$TMP/.chump-locks/ambient.jsonl")"
fi
rm -rf "$TMP"

# ── Test 7: Both alert types fire in one run ──────────────────────────────────
echo "[Test 7] Combined scenario: overweight + under-fed both emit"
TMP="$(setup_repo)"
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    cd "$TMP"
    # 10 EFFECTIVE (dominant), 1 CREDIBLE (under-fed), nothing else
    for i in $(seq 1 10); do reserve_gap "EFFECTIVE: combo-$i"; done
    reserve_gap "CREDIBLE: combo-1"
    : > "$TMP/.chump-locks/ambient.jsonl"
    AMBIENT="$TMP/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1
    exit $?
) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "combined scenario exits non-zero"
else
    fail "combined scenario should exit non-zero"
fi
# Use grep -c with || true to avoid Bash set -e triggering on no-match (fix for || echo 0 double-output bug)
n_under=$(grep -c '"kind":"pillar_balance_alert"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null || true)
n_over=$(grep -c '"kind":"pillar_balance_overweight"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null || true)
n_under=${n_under:-0}
n_over=${n_over:-0}
if [[ "$n_under" -gt 0 && "$n_over" -gt 0 ]]; then
    ok "both pillar_balance_alert and pillar_balance_overweight emitted"
else
    fail "expected both alert types; got under=$n_under over=$n_over"
fi
rm -rf "$TMP"

# ── Test 8: AMBIENT mkdir -p (no pre-existing .chump-locks/) ─────────────────
echo "[Test 8] Script creates AMBIENT directory if absent"
TMP="$(setup_repo)"
rm -rf "$TMP/.chump-locks"   # remove so the script must create it
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    cd "$TMP"
    reserve_gap "EFFECTIVE: mkdir-a"
    AMBIENT="$TMP/.chump-locks/ambient.jsonl" bash "$SCRIPT" >/dev/null 2>&1
    exit $?
) && rc=0 || rc=$?
# We don't care about exit code here — just that it didn't crash
if [[ -d "$TMP/.chump-locks" ]]; then
    ok "script created .chump-locks/ directory when absent"
else
    fail "script failed to create .chump-locks/ directory"
fi
rm -rf "$TMP"

# ── Test 9: audit-priorities output mentions pillar balance ──────────────────
echo "[Test 9] chump gap audit-priorities includes pillar balance result (AC5)"
TMP="$(setup_repo)"
(
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    cd "$TMP"
    # Create an unbalanced state so audit runs the check
    for i in $(seq 1 5); do reserve_gap "RESILIENT: audit-$i"; done
    audit_out=$("$CHUMP_BIN" gap audit-priorities 2>&1 || true)
    printf '%s' "$audit_out" | grep -qi "pillar balance" && exit 0 || exit 1
) && ok "audit-priorities output mentions pillar balance" \
  || fail "audit-priorities output should mention pillar balance"
rm -rf "$TMP"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
