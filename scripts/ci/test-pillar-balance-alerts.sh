#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Validates scripts/ops/pillar-balance-check.sh:
#  T1  script exists and is executable
#  T2  exit 0 + OK message on balanced fixture (2 per pillar)
#  T3  kind=pillar_balance_alert emitted for starved pillar (count < 2)
#  T4  alert JSON has required fields: ts, kind, pillar, count, floor, total_pickable
#  T5  exit non-zero when any pillar < floor
#  T6  kind=pillar_balance_overweight emitted when one pillar > 50% of total
#  T7  overweight JSON has required fields: ts, kind, pillar, count, pct, total_pickable
#  T8  exit non-zero on overweight even when all pillars >= floor
#  T9  CHUMP_PILLAR_BALANCE_CHECK_DISABLE=1 exits 0 and emits nothing
#  T10 --json flag outputs valid JSON with expected keys
#  T11 audit-priorities calls pillar-balance-check and surfaces result
#
# Uses INFRA-481-aware binary lookup; no network I/O.

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── T1: script exists and is executable ──────────────────────────────────────
if [ -x "$SCRIPT" ]; then
    ok "T1: pillar-balance-check.sh exists and is executable"
else
    fail "T1: pillar-balance-check.sh missing or not executable at $SCRIPT"
fi

# ── Binary location (INFRA-481 shared target-dir) ────────────────────────────
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [ ! -x "$BIN" ] && [ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]; then
    BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
fi
if [ ! -x "$BIN" ]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi
if [ ! -x "$BIN" ]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "PASS=$PASS  FAIL=$FAIL"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi
export CHUMP_BIN="$BIN"

# ── Shared fixture helpers ────────────────────────────────────────────────────
_make_fixture() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump" "$tmp/docs/gaps"
    cd "$tmp"
    git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
    git -C "$tmp" config user.email "test@ci.local" 2>/dev/null || true
    git -C "$tmp" config user.name "CI" 2>/dev/null || true
    printf '%s' "$tmp"
}

_reserve() {
    "$BIN" gap reserve \
        --domain INFRA --force --force-duplicate \
        --priority "${2:-P1}" --effort "${3:-xs}" \
        --acceptance-criteria "verify this works" \
        --title "$1" >/dev/null 2>&1
}

# ── T2: exit 0 + OK message on balanced fixture ──────────────────────────────
echo "--- T2: balanced fixture (2 per pillar) ---"
TMP2="$(_make_fixture)"
trap 'rm -rf "$TMP2"' EXIT
export CHUMP_REPO="$TMP2"
export CHUMP_WORKTREE_ROOT="$TMP2"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    _reserve "${p}: gap-a-$$"
    _reserve "${p}: gap-b-$$"
done

AMBIENT2="$TMP2/.chump-locks/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT2"

if bash "$SCRIPT" 2>/dev/null; then
    ok "T2a: exit 0 on balanced registry"
else
    fail "T2a: should exit 0 on balanced registry (all pillars >= 2)"
fi
out2=$(bash "$SCRIPT" 2>/dev/null)
if echo "$out2" | grep -qi "OK\|balance ok"; then
    ok "T2b: OK message printed on balanced registry"
else
    fail "T2b: missing OK message — got: $out2"
fi

# ── T3: kind=pillar_balance_alert emitted for starved pillar ─────────────────
echo ""
echo "--- T3/T4/T5: starved CREDIBLE pillar ---"
TMP3="$(_make_fixture)"
OLD3="$CHUMP_REPO"
export CHUMP_REPO="$TMP3"
export CHUMP_WORKTREE_ROOT="$TMP3"
AMBIENT3="$TMP3/.chump-locks/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT3"
trap 'rm -rf "$TMP3"' EXIT

# Seed 2 each of EFFECTIVE/RESILIENT/ZERO-WASTE but 0 CREDIBLE
for p in EFFECTIVE RESILIENT ZERO-WASTE; do
    _reserve "${p}: gap-a-$$"
    _reserve "${p}: gap-b-$$"
done

# T5: exit non-zero
if bash "$SCRIPT" >/dev/null 2>&1; then
    fail "T5: should exit non-zero when CREDIBLE < floor"
else
    ok "T5: exit non-zero when pillar starved"
fi

bash "$SCRIPT" >/dev/null 2>&1 || true  # populate ambient log

# T3: alert emitted
if [ -f "$AMBIENT3" ] && grep -q '"kind":"pillar_balance_alert"' "$AMBIENT3"; then
    ok "T3: kind=pillar_balance_alert written to ambient.jsonl"
else
    fail "T3: pillar_balance_alert not found in ambient.jsonl (path=$AMBIENT3)"
fi

# T4: alert has required fields
if [ -f "$AMBIENT3" ]; then
    alert_line=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT3" | head -1)
    missing_fields=""
    for field in ts kind pillar count floor total_pickable; do
        echo "$alert_line" | grep -q "\"$field\"" || missing_fields="$missing_fields $field"
    done
    if [ -z "$missing_fields" ]; then
        ok "T4: pillar_balance_alert has all required fields"
    else
        fail "T4: pillar_balance_alert missing fields:$missing_fields — line: $alert_line"
    fi
fi

# Verify pillar field says CREDIBLE
if [ -f "$AMBIENT3" ] && grep '"kind":"pillar_balance_alert"' "$AMBIENT3" | grep -q '"pillar":"CREDIBLE"'; then
    ok "T4b: alert correctly identifies CREDIBLE as starved pillar"
else
    fail "T4b: alert pillar field does not say CREDIBLE"
fi

export CHUMP_REPO="$TMP2"
export CHUMP_WORKTREE_ROOT="$TMP2"
export CHUMP_AMBIENT_LOG="$AMBIENT2"

# ── T6/T7/T8: overweight (one pillar > 50% of total) ────────────────────────
echo ""
echo "--- T6/T7/T8: overweight RESILIENT pillar ---"
TMP6="$(_make_fixture)"
export CHUMP_REPO="$TMP6"
export CHUMP_WORKTREE_ROOT="$TMP6"
AMBIENT6="$TMP6/.chump-locks/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT6"
trap 'rm -rf "$TMP6"' EXIT

# Seed 5 RESILIENT + 2 others (RESILIENT = 5/7 = 71%, over 50%)
for i in 1 2 3 4 5; do _reserve "RESILIENT: gap-$i-$$"; done
_reserve "EFFECTIVE: gap-a-$$"
_reserve "EFFECTIVE: gap-b-$$"

# T8: exit non-zero (overweight fires even when floor met for RESILIENT=5>=2)
if bash "$SCRIPT" >/dev/null 2>&1; then
    fail "T8: should exit non-zero when a pillar dominates > 50%"
else
    ok "T8: exit non-zero on overweight pillar"
fi

bash "$SCRIPT" >/dev/null 2>&1 || true

# T6: overweight event emitted
if [ -f "$AMBIENT6" ] && grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT6"; then
    ok "T6: kind=pillar_balance_overweight written to ambient.jsonl"
else
    fail "T6: pillar_balance_overweight not found in ambient.jsonl"
fi

# T7: overweight has required fields
if [ -f "$AMBIENT6" ]; then
    ow_line=$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT6" | head -1)
    missing_ow=""
    for field in ts kind pillar count pct total_pickable; do
        echo "$ow_line" | grep -q "\"$field\"" || missing_ow="$missing_ow $field"
    done
    if [ -z "$missing_ow" ]; then
        ok "T7: pillar_balance_overweight has all required fields"
    else
        fail "T7: pillar_balance_overweight missing fields:$missing_ow — line: $ow_line"
    fi
fi

export CHUMP_REPO="$TMP2"
export CHUMP_WORKTREE_ROOT="$TMP2"
export CHUMP_AMBIENT_LOG="$AMBIENT2"

# ── T9: CHUMP_PILLAR_BALANCE_CHECK_DISABLE=1 exits 0, emits nothing ──────────
echo ""
echo "--- T9: CHUMP_PILLAR_BALANCE_CHECK_DISABLE=1 bypass ---"
TMP9="$(_make_fixture)"
AMBIENT9="$TMP9/.chump-locks/ambient.jsonl"
export CHUMP_REPO="$TMP9"
export CHUMP_WORKTREE_ROOT="$TMP9"
export CHUMP_AMBIENT_LOG="$AMBIENT9"
trap 'rm -rf "$TMP9"' EXIT

# Seed unbalanced registry (would alert)
_reserve "RESILIENT: gap-a-$$"

if CHUMP_PILLAR_BALANCE_CHECK_DISABLE=1 bash "$SCRIPT" >/dev/null 2>&1; then
    ok "T9a: DISABLE=1 exits 0 despite unbalanced registry"
else
    fail "T9a: DISABLE=1 should exit 0"
fi

if [ ! -f "$AMBIENT9" ] || ! grep -q '"kind":"pillar_balance' "$AMBIENT9" 2>/dev/null; then
    ok "T9b: DISABLE=1 emits no alert events"
else
    fail "T9b: DISABLE=1 should not emit alert events"
fi

export CHUMP_REPO="$TMP2"
export CHUMP_WORKTREE_ROOT="$TMP2"
export CHUMP_AMBIENT_LOG="$AMBIENT2"

# ── T10: --json outputs valid JSON with expected keys ─────────────────────────
echo ""
echo "--- T10: --json output ---"
json_out=$(bash "$SCRIPT" --json 2>/dev/null)
missing_json=""
for key in total_pickable pillars floor alerts_fired; do
    echo "$json_out" | grep -q "\"$key\"" || missing_json="$missing_json $key"
done
if [ -z "$missing_json" ]; then
    ok "T10a: --json output has all required keys"
else
    fail "T10a: --json missing keys:$missing_json — got: $json_out"
fi
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    if echo "$json_out" | grep -q "\"$p\""; then
        ok "T10b: --json pillars.$p present"
    else
        fail "T10b: --json missing pillars.$p"
    fi
done

# ── T11: audit-priorities references pillar-balance-check ───────────────────
echo ""
echo "--- T11: audit-priorities wires pillar-balance-check ---"
if grep -q "pillar.balance.check\|pillar_balance_check" "$REPO_ROOT/src/main.rs"; then
    ok "T11a: src/main.rs references pillar-balance-check"
else
    fail "T11a: src/main.rs does not reference pillar-balance-check"
fi

# Run audit-priorities against the balanced fixture — output should mention pillar balance
ap_out=$("$BIN" gap audit-priorities 2>&1 || true)
if echo "$ap_out" | grep -qi "pillar.balance\|pillar_balance\|pillar balance"; then
    ok "T11b: audit-priorities output includes pillar balance section"
else
    fail "T11b: audit-priorities output missing pillar balance — got: $ap_out"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
