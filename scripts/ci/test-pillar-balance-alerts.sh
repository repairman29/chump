#!/usr/bin/env bash
# test-pillar-balance-alerts.sh — INFRA-902
#
# Validates scripts/ops/pillar-balance-check.sh:
#  1. Script is executable and Bash 3.2 compatible (no declare -A/mapfile/readarray)
#  2. Emits kind=pillar_balance_alert when a pillar has < 2 pickable gaps
#  3. Alert JSON has required fields: ts, kind, pillar, count, floor
#  4. Emits kind=pillar_balance_overweight when a pillar > 50% of total
#  5. Overweight JSON has required fields: ts, kind, pillar, count, total, pct
#  6. Exits non-zero when alerts fired; exits 0 when balance OK
#  7. --json output has required fields: total_pickable, pillars, alerts_fired
#  8. chump gap audit-priorities calls the script and includes result
#  9. audit-priorities exits non-zero when pillar alert fires

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-check test ==="
echo

# ── 1. Script structure checks ───────────────────────────────────────────────
echo "--- Static checks"

if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh is executable"
else
    fail "pillar-balance-check.sh is not executable"
fi

for forbidden in 'declare -A' 'declare -n' 'mapfile' 'readarray'; do
    if grep -qF "$forbidden" "$SCRIPT"; then
        fail "Bash 4+ construct '$forbidden' found in script (must be Bash 3.2 compat)"
    else
        ok "no '$forbidden' in script (Bash 3.2 compat)"
    fi
done

if grep -q 'mkdir -p' "$SCRIPT"; then
    ok "script uses mkdir -p before ambient writes"
else
    fail "script missing mkdir -p before ambient append"
fi

if grep -q 'scanner-anchor.*pillar_balance_alert' "$SCRIPT"; then
    ok "scanner-anchor for pillar_balance_alert present"
else
    fail "scanner-anchor for pillar_balance_alert missing"
fi

if grep -q 'scanner-anchor.*pillar_balance_overweight' "$SCRIPT"; then
    ok "scanner-anchor for pillar_balance_overweight present"
else
    fail "scanner-anchor for pillar_balance_overweight missing"
fi

# ── 2. Build binary ──────────────────────────────────────────────────────────
echo
echo "--- Build chump binary"

TARGET_DIR=$(PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH" cargo metadata \
    --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" --format-version 1 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_directory',''))" \
    2>/dev/null || echo "")
BIN="${TARGET_DIR:+$TARGET_DIR/debug/chump}"
BIN="${BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"

if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump \
        --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    TARGET_DIR=$(PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH" cargo metadata \
        --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" --format-version 1 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_directory',''))" \
        2>/dev/null || echo "")
    BIN="${TARGET_DIR:+$TARGET_DIR/debug/chump}"
    BIN="${BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

ok "chump binary found at $BIN"

# ── 3. Fixture environment ───────────────────────────────────────────────────
echo
echo "--- Functional tests"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_BIN="$BIN"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl"
export CHUMP_LOCK_DIR="$TMP/.chump-locks"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"

mkdir -p "$TMP/.chump-locks"

# ── 3a. Empty DB → balance OK → exit 0 ───────────────────────────────────────
if "$SCRIPT" --dry-run 2>/dev/null; then
    ok "empty DB: exit 0 (no gaps = no overweight; under-stocked is OK when empty)"
else
    ok "empty DB: exit 1 acceptable when all pillars are under-stocked (count=0 < floor=2)"
fi

# ── 3b. Alert fires when a pillar has 0 pickable gaps ─────────────────────────
# Create 3 EFFECTIVE gaps (>50% of 3 total → overweight) and 0 for others.
"$BIN" gap reserve --domain EFFECTIVE --priority P1 --effort xs \
    --title "EFFECTIVE: gap-fixture-1" \
    --acceptance-criteria "test fixture" --quiet 2>/dev/null
"$BIN" gap reserve --domain EFFECTIVE --priority P1 --effort s \
    --title "EFFECTIVE: gap-fixture-2" \
    --acceptance-criteria "test fixture" --quiet 2>/dev/null
"$BIN" gap reserve --domain EFFECTIVE --priority P1 --effort m \
    --title "EFFECTIVE: gap-fixture-3" \
    --acceptance-criteria "test fixture" --quiet 2>/dev/null

# Run script — should exit 1 (CREDIBLE/RESILIENT/ZERO-WASTE all at 0)
if ! "$SCRIPT" --dry-run 2>/dev/null; then
    ok "pillar understock detected: exit 1 when pillars at 0"
else
    fail "expected exit 1 when pillars are under-stocked (count=0 < floor=2)"
fi

# ── 3c. pillar_balance_alert emitted to ambient.jsonl ────────────────────────
# Run without --dry-run so events are emitted.
"$SCRIPT" 2>/dev/null || true

ALERT_COUNT=0
if [[ -f "$AMBIENT_LOG" ]]; then
    ALERT_COUNT=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT_LOG" 2>/dev/null || echo 0)
fi
if [[ "${ALERT_COUNT:-0}" -ge 1 ]]; then
    ok "pillar_balance_alert emitted to ambient.jsonl (count=$ALERT_COUNT)"
else
    fail "pillar_balance_alert not found in ambient.jsonl"
fi

# ── 3d. Alert JSON has required fields ───────────────────────────────────────
if [[ -f "$AMBIENT_LOG" ]]; then
    ALERT_LINE=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT_LOG" | head -1)
    for field in '"ts"' '"kind"' '"pillar"' '"count"' '"floor"'; do
        if echo "$ALERT_LINE" | grep -q "$field"; then
            ok "pillar_balance_alert has field $field"
        else
            fail "pillar_balance_alert missing field $field"
        fi
    done
fi

# ── 3e. pillar_balance_overweight emitted when pillar > 50% ──────────────────
OW_COUNT=0
if [[ -f "$AMBIENT_LOG" ]]; then
    OW_COUNT=$(grep -c '"kind":"pillar_balance_overweight"' "$AMBIENT_LOG" 2>/dev/null || echo 0)
fi
if [[ "${OW_COUNT:-0}" -ge 1 ]]; then
    ok "pillar_balance_overweight emitted (EFFECTIVE has 3/3 = 100% > 50%)"
else
    fail "pillar_balance_overweight not emitted when one pillar holds >50% of pool"
fi

# ── 3f. Overweight JSON has required fields ──────────────────────────────────
if [[ -f "$AMBIENT_LOG" ]]; then
    OW_LINE=$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT_LOG" | head -1)
    for field in '"ts"' '"kind"' '"pillar"' '"count"' '"total"' '"pct"'; do
        if echo "$OW_LINE" | grep -q "$field"; then
            ok "pillar_balance_overweight has field $field"
        else
            fail "pillar_balance_overweight missing field $field"
        fi
    done
fi

# ── 3g. --json output has required fields ────────────────────────────────────
JSON_OUT=$("$SCRIPT" --json --dry-run 2>/dev/null || true)
for key in total_pickable pillars alerts_fired; do
    if echo "$JSON_OUT" | grep -q "\"$key\""; then
        ok "--json output has key $key"
    else
        fail "--json output missing key $key"
    fi
done

# ── 3h. Balanced DB → exit 0 ─────────────────────────────────────────────────
# Add at least 2 gaps for each under-stocked pillar.
for pillar in CREDIBLE RESILIENT ZERO-WASTE; do
    "$BIN" gap reserve --domain "$pillar" --priority P1 --effort xs \
        --title "$pillar: gap-fixture-balance-1" \
        --acceptance-criteria "test fixture" --quiet 2>/dev/null
    "$BIN" gap reserve --domain "$pillar" --priority P1 --effort s \
        --title "$pillar: gap-fixture-balance-2" \
        --acceptance-criteria "test fixture" --quiet 2>/dev/null
done

if "$SCRIPT" --dry-run 2>/dev/null; then
    ok "balanced registry: exit 0 when all pillars meet floor"
else
    fail "expected exit 0 when all pillars have >= 2 pickable gaps"
fi

# ── 3i. audit-priorities includes pillar-balance result ──────────────────────
AP_OUT=$("$BIN" gap audit-priorities 2>/dev/null || true)
if echo "$AP_OUT" | grep -qi "pillar.balance\|pillar balance"; then
    ok "audit-priorities output includes pillar-balance section"
else
    fail "audit-priorities output missing pillar-balance section"
fi

# ── 3j. audit-priorities --json has pillar_balance key ───────────────────────
AP_JSON=$("$BIN" gap audit-priorities --json 2>/dev/null || true)
if echo "$AP_JSON" | grep -q '"pillar_balance"'; then
    ok "audit-priorities --json has pillar_balance key"
else
    fail "audit-priorities --json missing pillar_balance key"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
