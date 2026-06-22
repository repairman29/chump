#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests pillar-balance-check.sh:
#  AC1: reads state.db via chump gap list --status open
#  AC2: emits kind=pillar_balance_alert (pillar, count, floor=2) when count < 2
#  AC3: emits kind=pillar_balance_overweight (pillar, count, pct) when count > 50%
#  AC4: exits non-zero if any alert fired
#  AC5: chump gap audit-priorities calls the script
#  AC6: 8+ tests covering all alert types and exit codes

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: script exists and is executable ───────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable at $SCRIPT"
fi

# ── Build chump binary ────────────────────────────────────────────────────────
# INFRA-481: honor CARGO_TARGET_DIR / cargo metadata target-dir (worktree-safe)
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
else
    META_TARGET="$(cargo metadata --format-version 1 --no-deps \
        --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])" 2>/dev/null || echo "")"
    CHUMP_BIN="${META_TARGET:-$REPO_ROOT/target}/debug/chump"
fi
export CHUMP_BIN

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -3
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    fail "chump binary not found after build — aborting"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# ── Fixture setup ─────────────────────────────────────────────────────────────
# IMPORTANT: call new_fixture directly (NOT in $()) so exports reach parent shell.
# INFRA-1149: export CHUMP_GAP_RESERVE_NO_SIMILARITY=1 so 2nd+ reserves don't block.
FIXTURE_DIR=""
FIXTURE_CLEANUP=""

new_fixture() {
    # Clean up previous fixture if any
    if [[ -n "$FIXTURE_CLEANUP" ]]; then
        rm -rf "$FIXTURE_CLEANUP"
        FIXTURE_CLEANUP=""
    fi
    FIXTURE_DIR="$(mktemp -d)"
    FIXTURE_CLEANUP="$FIXTURE_DIR"
    mkdir -p "$FIXTURE_DIR/.chump" "$FIXTURE_DIR/.chump-locks" "$FIXTURE_DIR/docs/gaps"
    # Run git init in subshell so we don't change our CWD
    (cd "$FIXTURE_DIR" && git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true) 2>/dev/null
    (cd "$FIXTURE_DIR" && git config user.email "test@ci.local" 2>/dev/null || true) 2>/dev/null
    (cd "$FIXTURE_DIR" && git config user.name "CI" 2>/dev/null || true) 2>/dev/null
    export CHUMP_REPO="$FIXTURE_DIR"
    export CHUMP_HOME="$FIXTURE_DIR"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export AMBIENT="$FIXTURE_DIR/.chump-locks/ambient.jsonl"
}

trap 'rm -rf "$FIXTURE_CLEANUP"' EXIT

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --acceptance-criteria "$ac" --force --force-duplicate \
        --quiet 2>/dev/null || true
}

# ── Test 2: AC5 — audit-priorities wires in pillar-balance-check.sh ──────────
echo "[Test 2] AC5: audit-priorities calls pillar-balance-check.sh"
if grep -qE 'pbc_path|pillar.balance.check|pillar_balance_check|pillar.balance.healthy|pillar.balance.result' \
        "$REPO_ROOT/src/main.rs"; then
    ok "src/main.rs references pillar-balance-check integration"
else
    fail "src/main.rs missing pillar-balance-check.sh integration in audit-priorities"
fi

# ── Test 3: balanced pillars (2 per pillar) → exit 0, no alerts ──────────────
echo "[Test 3] Balanced pillars (2 per pillar) → exit 0"
new_fixture
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balanced-gap-alpha"
    reserve_gap "${p}: balanced-gap-beta"
done
if bash "$SCRIPT" >/dev/null 2>&1; then
    ok "balanced pillars (2 each) exit 0"
else
    fail "balanced pillars (2 each) should exit 0"
fi
alert_count=0
if [[ -f "$AMBIENT" ]]; then
    alert_count=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null || echo 0)
fi
if [[ "${alert_count:-0}" -eq 0 ]]; then
    ok "no pillar_balance_alert events emitted for balanced pillars"
else
    fail "unexpected pillar_balance_alert events in balanced fixture (count=$alert_count)"
fi

# ── Test 4: AC2 — under-fed pillar (0 gaps) emits pillar_balance_alert ────────
echo "[Test 4] AC2: under-fed pillar emits pillar_balance_alert"
new_fixture
for p in EFFECTIVE CREDIBLE RESILIENT; do
    reserve_gap "${p}: underfed-test-a"
    reserve_gap "${p}: underfed-test-b"
done
# ZERO-WASTE has 0 gaps — should alert
bash "$SCRIPT" >/dev/null 2>&1 && rc4=0 || rc4=$?
if [[ "${rc4:-0}" -ne 0 ]]; then
    ok "under-fed pillar (ZERO-WASTE=0) exits non-zero (AC4)"
else
    fail "under-fed pillar should exit non-zero"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_alert emitted for under-fed pillar (AC2)"
else
    fail "pillar_balance_alert not emitted for under-fed ZERO-WASTE"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"pillar":"ZERO-WASTE"' "$AMBIENT" 2>/dev/null; then
    ok "pillar field is ZERO-WASTE in alert (AC2)"
else
    fail "pillar field missing or wrong in pillar_balance_alert"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"floor":2' "$AMBIENT" 2>/dev/null; then
    ok "floor=2 present in pillar_balance_alert (AC2)"
else
    fail "floor=2 missing from pillar_balance_alert"
fi

# ── Test 5: AC2 — pillar with exactly 1 gap also triggers alert ──────────────
echo "[Test 5] AC2: pillar with count=1 triggers alert"
new_fixture
for p in EFFECTIVE CREDIBLE RESILIENT; do
    reserve_gap "${p}: one-alert-a"
    reserve_gap "${p}: one-alert-b"
done
reserve_gap "ZERO-WASTE: only-one"  # count=1 → under floor=2
bash "$SCRIPT" >/dev/null 2>&1 && rc5=0 || rc5=$?
if [[ "${rc5:-0}" -ne 0 ]]; then
    ok "pillar with count=1 exits non-zero (AC4)"
else
    fail "pillar with count=1 should exit non-zero"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"count":1' "$AMBIENT" 2>/dev/null; then
    ok "count=1 reported correctly in pillar_balance_alert"
else
    fail "count=1 not found in alert"
fi

# ── Test 6: AC3 — overweight pillar (>50%) emits pillar_balance_overweight ────
echo "[Test 6] AC3: overweight pillar emits pillar_balance_overweight"
new_fixture
# 10 EFFECTIVE gaps, 2 each for others → EFFECTIVE=10/16=62.5% > 50%
for i in $(seq 1 10); do reserve_gap "EFFECTIVE: overweight-gap-$i"; done
reserve_gap "CREDIBLE: baseline-a"
reserve_gap "CREDIBLE: baseline-b"
reserve_gap "RESILIENT: baseline-a"
reserve_gap "RESILIENT: baseline-b"
reserve_gap "ZERO-WASTE: baseline-a"
reserve_gap "ZERO-WASTE: baseline-b"
bash "$SCRIPT" >/dev/null 2>&1 && rc6=0 || rc6=$?
if [[ "${rc6:-0}" -ne 0 ]]; then
    ok "overweight EFFECTIVE pillar exits non-zero (AC4)"
else
    fail "overweight pillar should exit non-zero"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null; then
    ok "pillar_balance_overweight emitted (AC3)"
else
    fail "pillar_balance_overweight not emitted"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"pillar":"EFFECTIVE"' "$AMBIENT" 2>/dev/null; then
    ok "pillar=EFFECTIVE in overweight alert (AC3)"
else
    fail "pillar field missing or wrong in overweight alert"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"pct":' "$AMBIENT" 2>/dev/null; then
    ok "pct field present in overweight alert (AC3)"
else
    fail "pct field missing from pillar_balance_overweight"
fi

# ── Test 7: m-effort and P2 gaps NOT counted as pickable ─────────────────────
echo "[Test 7] m-effort and P2 gaps are not counted as pickable"
new_fixture
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: pickable-a"
    reserve_gap "${p}: pickable-b"
done
# Non-pickable gaps — must be ignored
reserve_gap "EFFECTIVE: medium-effort-gap" "P1" "m"
reserve_gap "CREDIBLE: p2-gap"            "P2" "xs"
if bash "$SCRIPT" >/dev/null 2>&1; then
    ok "m-effort and P2 gaps ignored → still balanced, exit 0"
else
    fail "m-effort/P2 gaps should be ignored — expected exit 0"
fi

# ── Test 8: AC1 — summary line is printed with pillar counts ─────────────────
echo "[Test 8] AC1: summary output includes per-pillar counts"
new_fixture
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: summary-test-a"
    reserve_gap "${p}: summary-test-b"
done
OUTPUT="$(bash "$SCRIPT" 2>&1 || true)"
if echo "$OUTPUT" | grep -q "pillar-balance.*pickable="; then
    ok "summary line with pickable= present (AC1)"
else
    fail "summary line missing from pillar-balance-check.sh output"
fi
if echo "$OUTPUT" | grep -q "EFFECTIVE="; then
    ok "EFFECTIVE= in summary output (AC1)"
else
    fail "EFFECTIVE= missing from summary output"
fi

# ── Test 9: empty gap store → all pillars at 0 → 4 alerts ───────────────────
echo "[Test 9] Empty gap store → all 4 pillars alert"
new_fixture
bash "$SCRIPT" >/dev/null 2>&1 && rc9=0 || rc9=$?
if [[ "${rc9:-0}" -ne 0 ]]; then
    ok "empty gap store exits non-zero"
else
    fail "empty gap store should exit non-zero (all pillars under-fed)"
fi
alert_count9=0
if [[ -f "$AMBIENT" ]]; then
    alert_count9=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null || echo 0)
fi
if [[ "${alert_count9:-0}" -ge 4 ]]; then
    ok "4+ pillar_balance_alert events for empty store (got $alert_count9)"
else
    fail "expected >=4 alerts for empty store (got ${alert_count9:-0})"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
