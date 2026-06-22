#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Validates scripts/ops/pillar-balance-check.sh:
#  1. Script file exists and is executable
#  2. pillar_balance_alert schema: pillar, count, floor fields present
#  3. pillar_balance_overweight schema: pillar, count, pct fields present
#  4. Under-fed threshold: count < 2 fires alert
#  5. Exactly-at-floor (count == 2): no alert
#  6. Overweight: one pillar > 50% of pool fires overweight alert
#  7. Exit code non-zero when alerts fired
#  8. Exit code 0 when all pillars healthy
#  9. --dry-run: does NOT append to ambient.jsonl
# 10. mkdir -p: ambient dir created if absent
# 11. chump gap audit-priorities calls pillar-balance-check.sh

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts test ==="
echo

# ── Test 1: Script exists and is executable ───────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh missing or not executable at $SCRIPT"
fi

# ── Test 11: audit-priorities integration wired in main.rs ───────────────────
if grep -q "pillar.balance.check\|pillar-balance-check" "$REPO_ROOT/src/main.rs"; then
    ok "audit-priorities wired to call pillar-balance-check"
else
    fail "pillar-balance-check.sh not referenced in src/main.rs audit-priorities"
fi

# ── Binary resolution (INFRA-481 shared target-dir) ───────────────────────────
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])" 2>/dev/null \
    || echo "$REPO_ROOT/target")"

BIN="$TARGET_DIR/debug/chump"
if [[ ! -x "$BIN" ]]; then
    BIN="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    BIN="$TARGET_DIR/debug/chump"
    if [[ ! -x "$BIN" ]]; then
        BIN="$REPO_ROOT/target/debug/chump"
    fi
fi
if [[ ! -x "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

export CHUMP_BIN="$BIN"

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    "$BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --quiet --force-duplicate 2>/dev/null
}

# ── Fixture helpers ────────────────────────────────────────────────────────────
make_fixture_dir() {
    local tmp; tmp="$(mktemp -d)"
    export CHUMP_REPO="$tmp"
    export CHUMP_HOME="$tmp"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    printf '%s' "$tmp"
}

# ── Test 8: Exit 0 when all pillars healthy (2 gaps each) ────────────────────
echo
echo "[healthy fixture — 2 gaps per pillar]"
FIXTURE_HEALTHY="$(make_fixture_dir)"
trap 'rm -rf "$FIXTURE_HEALTHY"' EXIT
AMBIENT_HEALTHY="$FIXTURE_HEALTHY/.chump-locks/ambient.jsonl"

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: balance-test-a"
    reserve_gap "${p}: balance-test-b"
done

if CHUMP_AMBIENT_OVERRIDE="$AMBIENT_HEALTHY" CHUMP_BIN="$BIN" bash "$SCRIPT" --quiet 2>/dev/null; then
    ok "healthy fixture exits 0"
else
    fail "healthy fixture should exit 0"
fi

if [[ ! -f "$AMBIENT_HEALTHY" ]] || ! grep -q "pillar_balance" "$AMBIENT_HEALTHY" 2>/dev/null; then
    ok "no alerts emitted for healthy fixture"
else
    fail "unexpected alerts emitted for healthy fixture"
fi

# ── Test 4 & 7: Under-fed pillar (< 2) fires alert, exits non-zero ───────────
echo
echo "[starved fixture — CREDIBLE has 0 gaps]"
FIXTURE_STARVED="$(make_fixture_dir)"
trap 'rm -rf "$FIXTURE_STARVED"' EXIT
AMBIENT_STARVED="$FIXTURE_STARVED/.chump-locks/ambient.jsonl"

for p in EFFECTIVE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: starved-test-a"
    reserve_gap "${p}: starved-test-b"
done
# CREDIBLE intentionally empty

RC=0
CHUMP_AMBIENT_OVERRIDE="$AMBIENT_STARVED" CHUMP_BIN="$BIN" bash "$SCRIPT" --quiet 2>/dev/null \
    || RC=$?

if [[ "$RC" -ne 0 ]]; then
    ok "starved fixture exits non-zero"
else
    fail "starved fixture should exit non-zero"
fi

# Test 4: alert emitted for the starved pillar
if [[ -f "$AMBIENT_STARVED" ]] && grep -q '"kind":"pillar_balance_alert"' "$AMBIENT_STARVED" 2>/dev/null; then
    ok "pillar_balance_alert emitted for starved pillar"
else
    fail "pillar_balance_alert not emitted for starved pillar"
fi

# Test 5: no alert for pillars AT floor (not in the alert output)
if grep '"kind":"pillar_balance_alert"' "$AMBIENT_STARVED" 2>/dev/null | grep -q '"pillar":"EFFECTIVE"'; then
    fail "EFFECTIVE at floor incorrectly triggered alert"
else
    ok "pillars at floor (EFFECTIVE=2) did not trigger alert"
fi

# ── Test 2: pillar_balance_alert schema ──────────────────────────────────────
echo
echo "[schema test — pillar_balance_alert fields]"
ALERT_LINE="$(grep '"kind":"pillar_balance_alert"' "$AMBIENT_STARVED" 2>/dev/null | head -1 || true)"
if [[ -n "$ALERT_LINE" ]]; then
    for field in pillar count floor; do
        if printf '%s' "$ALERT_LINE" | grep -q "\"${field}\""; then
            ok "pillar_balance_alert has field '$field'"
        else
            fail "pillar_balance_alert missing field '$field' — line: $ALERT_LINE"
        fi
    done
    # floor value must be 2
    if printf '%s' "$ALERT_LINE" | grep -q '"floor":2'; then
        ok "pillar_balance_alert floor=2"
    else
        fail "pillar_balance_alert floor is not 2 — line: $ALERT_LINE"
    fi
else
    fail "no pillar_balance_alert line found for schema test"
fi

# ── Test 3 & 6: Overweight pillar (> 50%) fires overweight alert ─────────────
echo
echo "[overweight fixture — EFFECTIVE has 10 of 12 gaps]"
FIXTURE_HEAVY="$(make_fixture_dir)"
trap 'rm -rf "$FIXTURE_HEAVY"' EXIT
AMBIENT_HEAVY="$FIXTURE_HEAVY/.chump-locks/ambient.jsonl"

for i in 1 2 3 4 5 6 7 8 9 10; do
    reserve_gap "EFFECTIVE: heavy-test-$i"
done
# One each of other pillars so total = 13 (EFFECTIVE at ~77%)
reserve_gap "CREDIBLE: heavy-test-1"
reserve_gap "RESILIENT: heavy-test-1"

RC_HEAVY=0
CHUMP_AMBIENT_OVERRIDE="$AMBIENT_HEAVY" CHUMP_BIN="$BIN" bash "$SCRIPT" --quiet 2>/dev/null \
    || RC_HEAVY=$?

if [[ "$RC_HEAVY" -ne 0 ]]; then
    ok "overweight fixture exits non-zero"
else
    fail "overweight fixture should exit non-zero (EFFECTIVE > 50%)"
fi

if [[ -f "$AMBIENT_HEAVY" ]] && grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT_HEAVY" 2>/dev/null; then
    ok "pillar_balance_overweight emitted for heavy pillar"
else
    fail "pillar_balance_overweight not emitted for heavy pillar"
fi

# Test 3: overweight schema fields
OW_LINE="$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT_HEAVY" 2>/dev/null | head -1 || true)"
if [[ -n "$OW_LINE" ]]; then
    for field in pillar count pct; do
        if printf '%s' "$OW_LINE" | grep -q "\"${field}\""; then
            ok "pillar_balance_overweight has field '$field'"
        else
            fail "pillar_balance_overweight missing field '$field' — line: $OW_LINE"
        fi
    done
else
    fail "no pillar_balance_overweight line found for schema test"
fi

# ── Test 9: --dry-run does NOT write to ambient.jsonl ────────────────────────
echo
echo "[dry-run test]"
FIXTURE_DRY="$(make_fixture_dir)"
trap 'rm -rf "$FIXTURE_DRY"' EXIT
AMBIENT_DRY="$FIXTURE_DRY/.chump-locks/ambient.jsonl"

# Starved fixture so alerts would fire
reserve_gap "EFFECTIVE: dry-test-1"

CHUMP_AMBIENT_OVERRIDE="$AMBIENT_DRY" CHUMP_BIN="$BIN" bash "$SCRIPT" --dry-run --quiet 2>/dev/null || true

if [[ ! -f "$AMBIENT_DRY" ]] || [[ ! -s "$AMBIENT_DRY" ]]; then
    ok "--dry-run does not write to ambient.jsonl"
else
    fail "--dry-run should not write to ambient.jsonl"
fi

# ── Test 10: mkdir -p creates ambient dir if absent ──────────────────────────
echo
echo "[mkdir-p test]"
FIXTURE_MKDIRP="$(make_fixture_dir)"
trap 'rm -rf "$FIXTURE_MKDIRP"' EXIT
# Point ambient at a nested path that doesn't exist yet
AMBIENT_MKDIRP="$FIXTURE_MKDIRP/nested/deep/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$(dirname "$AMBIENT_MKDIRP")")"

reserve_gap "EFFECTIVE: mkdirp-test-1"

CHUMP_AMBIENT_OVERRIDE="$AMBIENT_MKDIRP" CHUMP_BIN="$BIN" bash "$SCRIPT" --quiet 2>/dev/null || true

if [[ -d "$(dirname "$AMBIENT_MKDIRP")" ]]; then
    ok "mkdir -p created ambient parent directory"
else
    fail "ambient parent directory was not created"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
