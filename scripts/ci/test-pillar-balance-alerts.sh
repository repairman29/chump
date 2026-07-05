#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Validates scripts/ops/pillar-balance-check.sh:
#  1. Script file exists and is executable
#  2. Balanced fixture (2 per pillar) → exit 0, no alerts
#  3. Underweight pillar (1 gap) → exit 1, pillar_balance_alert emitted
#  4. Alert JSON schema: pillar, count, floor=2
#  5. All-zero pillar (0 gaps) → alert for that pillar
#  6. Dominant pillar (>50%) → exit 1, pillar_balance_overweight emitted
#  7. Overweight JSON schema: pillar, count, pct, total
#  8. Exit 0 when all pillars at floor
#  9. Mixed: one underweight + one overweight → both alerts
# 10. High-effort (l/xl) gaps excluded from pickable count

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: Script exists and is executable ────────────────────────────────────
echo "[T1] script exists + executable"
if [[ -f "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists"
else
    fail "pillar-balance-check.sh missing at $SCRIPT"
fi
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh is executable"
else
    fail "pillar-balance-check.sh is not executable"
fi

# ── Resolve chump binary (INFRA-481: shared target dir) ───────────────────────
if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "$CHUMP_BIN" ]]; then
    BIN="$CHUMP_BIN"
elif [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
    BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
    BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
else
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    if [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
        BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
        BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    else
        fail "chump binary not found after build — skipping functional tests"
        echo
        echo "=== Results: $PASS passed, $FAIL failed ==="
        [[ "$FAIL" -eq 0 ]]
        exit
    fi
fi
export CHUMP_BIN="$BIN"
echo "  [bin] $BIN"
echo

# ── Fixture helpers ────────────────────────────────────────────────────────────
make_fixture() {
    local dir="$1"
    mkdir -p "$dir/.chump" "$dir/docs/gaps"
    cd "$dir"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git -C "$dir" config user.email "test@ci.local" 2>/dev/null || true
    git -C "$dir" config user.name  "CI"            2>/dev/null || true
    cd "$REPO_ROOT"
}

reserve_gap() {
    local title="$1"
    local prio="${2:-P1}"
    local effort="${3:-s}"
    "$BIN" gap reserve --domain INFRA --priority "$prio" --effort "$effort" \
        --title "$title" --quiet --force-duplicate 2>/dev/null || true
}

run_check() {
    local dir="$1"
    local ambient="$dir/.chump-locks/ambient.jsonl"
    mkdir -p "$dir/.chump-locks"
    CHUMP_BIN="$BIN" CHUMP_REPO="$dir" CHUMP_AMBIENT_LOG="$ambient" bash "$SCRIPT" 2>&1
}

run_check_exit() {
    local dir="$1"
    local ambient="$dir/.chump-locks/ambient.jsonl"
    mkdir -p "$dir/.chump-locks"
    CHUMP_BIN="$BIN" CHUMP_REPO="$dir" CHUMP_AMBIENT_LOG="$ambient" bash "$SCRIPT" >/dev/null 2>&1
    echo $?
}

read_ambient() {
    local dir="$1"
    cat "$dir/.chump-locks/ambient.jsonl" 2>/dev/null || true
}

# ── T2: Balanced fixture → exit 0, no alerts ──────────────────────────────────
echo "[T2] balanced fixture — 2 gaps per pillar"
TMP2="$(mktemp -d)"
trap 'rm -rf "$TMP2"' EXIT
make_fixture "$TMP2"

(
    export CHUMP_REPO="$TMP2"
    export CHUMP_HOME="$TMP2"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
        reserve_gap "${p}: fixture-a" P1 s
        reserve_gap "${p}: fixture-b" P1 s
    done
)

exit_code=$(run_check_exit "$TMP2")
if [[ "$exit_code" -eq 0 ]]; then
    ok "balanced fixture exits 0"
else
    fail "balanced fixture should exit 0 — got $exit_code"
fi

ambient_events=$(read_ambient "$TMP2")
alert_count=$(printf '%s' "$ambient_events" | grep -c "pillar_balance_alert" || true)
ow_count=$(printf '%s' "$ambient_events" | grep -c "pillar_balance_overweight" || true)
if [[ "$alert_count" -eq 0 ]] && [[ "$ow_count" -eq 0 ]]; then
    ok "balanced fixture emits no alerts"
else
    fail "balanced fixture should emit 0 alerts — got alert=$alert_count overweight=$ow_count"
fi
rm -rf "$TMP2"

# ── T3: Underweight pillar (1 gap) → exit 1, alert emitted ────────────────────
echo "[T3] underweight pillar — CREDIBLE has only 1 gap"
TMP3="$(mktemp -d)"
trap 'rm -rf "$TMP3"' EXIT
make_fixture "$TMP3"

(
    export CHUMP_REPO="$TMP3"
    export CHUMP_HOME="$TMP3"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    reserve_gap "EFFECTIVE: t3-a"  P1 s
    reserve_gap "EFFECTIVE: t3-b"  P1 s
    reserve_gap "CREDIBLE: t3-a"   P1 s
    reserve_gap "RESILIENT: t3-a"  P1 s
    reserve_gap "RESILIENT: t3-b"  P1 s
    reserve_gap "ZERO-WASTE: t3-a" P1 s
    reserve_gap "ZERO-WASTE: t3-b" P1 s
)

exit_code=$(run_check_exit "$TMP3")
if [[ "$exit_code" -ne 0 ]]; then
    ok "underweight pillar exits non-zero"
else
    fail "underweight CREDIBLE should exit non-zero"
fi

ambient_events=$(read_ambient "$TMP3")
alert_lines=$(printf '%s' "$ambient_events" | grep "pillar_balance_alert" || true)
if [[ -n "$alert_lines" ]]; then
    ok "pillar_balance_alert emitted for underweight pillar"
else
    fail "pillar_balance_alert not emitted — ambient: $ambient_events"
fi

# T4: Alert JSON schema: pillar, count, floor=2
echo "[T4] alert JSON schema validation"
alert_line=$(printf '%s' "$ambient_events" | grep "pillar_balance_alert" | head -1)
for field in '"kind"' '"pillar"' '"count"' '"floor"'; do
    if printf '%s' "$alert_line" | grep -q "$field"; then
        ok "alert event has $field field"
    else
        fail "alert event missing $field — line: $alert_line"
    fi
done
if printf '%s' "$alert_line" | grep -q '"floor":2'; then
    ok "alert floor value is 2"
else
    fail "alert floor should be 2 — line: $alert_line"
fi
if printf '%s' "$alert_line" | grep -q '"CREDIBLE"'; then
    ok "alert identifies CREDIBLE as underweight pillar"
else
    fail "alert should identify CREDIBLE — line: $alert_line"
fi
rm -rf "$TMP3"

# ── T5: All-zero pillar → alert fired ─────────────────────────────────────────
echo "[T5] zero-gap pillars — CREDIBLE + ZERO-WASTE missing entirely"
TMP5="$(mktemp -d)"
trap 'rm -rf "$TMP5"' EXIT
make_fixture "$TMP5"

(
    export CHUMP_REPO="$TMP5"
    export CHUMP_HOME="$TMP5"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    reserve_gap "EFFECTIVE: t5-a"  P1 s
    reserve_gap "EFFECTIVE: t5-b"  P1 s
    reserve_gap "RESILIENT: t5-a"  P1 s
    reserve_gap "RESILIENT: t5-b"  P1 s
    # No CREDIBLE or ZERO-WASTE gaps
)

exit_code=$(run_check_exit "$TMP5")
if [[ "$exit_code" -ne 0 ]]; then
    ok "zero-gap pillars exit non-zero"
else
    fail "missing CREDIBLE+ZERO-WASTE should exit non-zero"
fi

ambient_events=$(read_ambient "$TMP5")
alert_count=$(printf '%s' "$ambient_events" | grep -c "pillar_balance_alert" || true)
if [[ "$alert_count" -ge 2 ]]; then
    ok "two pillar_balance_alert events emitted (CREDIBLE + ZERO-WASTE)"
else
    fail "expected >=2 alerts for zero-gap pillars — got $alert_count"
fi
rm -rf "$TMP5"

# ── T6: Dominant pillar (>50%) → overweight alert ─────────────────────────────
echo "[T6] dominant pillar — RESILIENT has 6/9 gaps (>50%)"
TMP6="$(mktemp -d)"
trap 'rm -rf "$TMP6"' EXIT
make_fixture "$TMP6"

(
    export CHUMP_REPO="$TMP6"
    export CHUMP_HOME="$TMP6"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    for i in 1 2 3 4 5 6; do
        reserve_gap "RESILIENT: dominant-$i" P1 s
    done
    reserve_gap "EFFECTIVE: t6-a"  P1 s
    reserve_gap "CREDIBLE: t6-a"   P1 s
    reserve_gap "ZERO-WASTE: t6-a" P1 s
)

exit_code=$(run_check_exit "$TMP6")
if [[ "$exit_code" -ne 0 ]]; then
    ok "dominant pillar exits non-zero"
else
    fail "dominant RESILIENT (6/9 gaps) should exit non-zero"
fi

ambient_events=$(read_ambient "$TMP6")
ow_line=$(printf '%s' "$ambient_events" | grep "pillar_balance_overweight" | head -1)
if [[ -n "$ow_line" ]]; then
    ok "pillar_balance_overweight emitted for dominant pillar"
else
    fail "pillar_balance_overweight not emitted — ambient: $ambient_events"
fi

# T7: Overweight JSON schema: pillar, count, pct, total
echo "[T7] overweight JSON schema validation"
for field in '"kind"' '"pillar"' '"count"' '"pct"' '"total"'; do
    if printf '%s' "$ow_line" | grep -q "$field"; then
        ok "overweight event has $field field"
    else
        fail "overweight event missing $field — line: $ow_line"
    fi
done
if printf '%s' "$ow_line" | grep -q '"RESILIENT"'; then
    ok "overweight event identifies RESILIENT"
else
    fail "overweight event should identify RESILIENT — line: $ow_line"
fi
rm -rf "$TMP6"

# ── T8: Exit 0 when all pillars exactly at floor ──────────────────────────────
echo "[T8] pillars exactly at floor (2 each) → exit 0"
TMP8="$(mktemp -d)"
trap 'rm -rf "$TMP8"' EXIT
make_fixture "$TMP8"

(
    export CHUMP_REPO="$TMP8"
    export CHUMP_HOME="$TMP8"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
        reserve_gap "${p}: floor-a" P1 xs
        reserve_gap "${p}: floor-b" P0 s
    done
)

exit_code=$(run_check_exit "$TMP8")
if [[ "$exit_code" -eq 0 ]]; then
    ok "at-floor fixture exits 0"
else
    fail "at-floor fixture (2 per pillar) should exit 0 — got $exit_code"
fi
rm -rf "$TMP8"

# ── T9: Mixed: one underweight + one overweight → both alert types ─────────────
echo "[T9] mixed: EFFECTIVE underweight + RESILIENT overweight"
TMP9="$(mktemp -d)"
trap 'rm -rf "$TMP9"' EXIT
make_fixture "$TMP9"

(
    export CHUMP_REPO="$TMP9"
    export CHUMP_HOME="$TMP9"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    # EFFECTIVE: 1 (underweight), RESILIENT: 5 (overweight at 5/8=62%), others: 1 each
    reserve_gap "EFFECTIVE: t9-only"  P1 s
    for i in 1 2 3 4 5; do
        reserve_gap "RESILIENT: t9-$i" P1 s
    done
    reserve_gap "CREDIBLE: t9-a"   P1 s
    reserve_gap "ZERO-WASTE: t9-a" P1 s
)

exit_code=$(run_check_exit "$TMP9")
if [[ "$exit_code" -ne 0 ]]; then
    ok "mixed fixture exits non-zero"
else
    fail "mixed fixture should exit non-zero"
fi

ambient_events=$(read_ambient "$TMP9")
has_alert=$(printf '%s' "$ambient_events" | grep -c "pillar_balance_alert" || true)
has_ow=$(printf '%s' "$ambient_events" | grep -c "pillar_balance_overweight" || true)
if [[ "$has_alert" -ge 1 ]]; then
    ok "mixed: pillar_balance_alert emitted"
else
    fail "mixed: missing pillar_balance_alert"
fi
if [[ "$has_ow" -ge 1 ]]; then
    ok "mixed: pillar_balance_overweight emitted"
else
    fail "mixed: missing pillar_balance_overweight"
fi
rm -rf "$TMP9"

# ── T10: High-effort gaps (l/xl) excluded from pickable count ─────────────────
echo "[T10] large-effort gaps excluded from pickable"
TMP10="$(mktemp -d)"
trap 'rm -rf "$TMP10"' EXIT
make_fixture "$TMP10"

(
    export CHUMP_REPO="$TMP10"
    export CHUMP_HOME="$TMP10"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    # Only l-effort EFFECTIVE gaps — these should NOT be pickable
    reserve_gap "EFFECTIVE: large-a" P1 l
    reserve_gap "EFFECTIVE: large-b" P1 l
    # 2 pickable gaps for other pillars
    reserve_gap "CREDIBLE: t10-a"   P1 s
    reserve_gap "CREDIBLE: t10-b"   P1 s
    reserve_gap "RESILIENT: t10-a"  P1 s
    reserve_gap "RESILIENT: t10-b"  P1 s
    reserve_gap "ZERO-WASTE: t10-a" P1 s
    reserve_gap "ZERO-WASTE: t10-b" P1 s
)

out=$(run_check "$TMP10" || true)
# EFFECTIVE should be 0 pickable (l effort excluded), so alert expected
alert_lines=$(printf '%s' "$(read_ambient "$TMP10")" | grep "pillar_balance_alert" | grep '"EFFECTIVE"' || true)
if [[ -n "$alert_lines" ]]; then
    ok "l-effort EFFECTIVE gaps excluded → alert fired for EFFECTIVE"
else
    if printf '%s' "$out" | grep -q "EFFECTIVE=0"; then
        ok "l-effort EFFECTIVE gaps excluded (count=0 in output)"
    else
        fail "l-effort gaps should be excluded from pickable (EFFECTIVE should be 0)"
    fi
fi
rm -rf "$TMP10"

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
