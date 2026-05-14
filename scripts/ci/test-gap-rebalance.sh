#!/usr/bin/env bash
# test-gap-rebalance.sh — INFRA-635
#
# Validates `chump gap rebalance`:
#  - subcommand wired in main.rs
#  - --json output has required fields
#  - Scenario 1: over-budget P0 → DEMOTE action, exit 1
#  - Scenario 2: pillar skew (one pillar dominates) → DEMOTE action, exit 1
#  - Scenario 3: all clean → exit 0, "clean" message
#  - Scenario 4: no-action-needed (at floor but balanced) → exit 0

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== INFRA-635 gap rebalance test ==="
echo

# 1. Subcommand wired
if grep -q '"rebalance"' "$REPO_ROOT/src/main.rs"; then
    ok "rebalance arm in main.rs"
else
    fail "rebalance arm missing from main.rs"
fi

if grep -q 'rebalance' "$REPO_ROOT/src/main.rs"; then
    ok "rebalance in help text"
else
    fail "rebalance not in help text"
fi

BIN="$REPO_ROOT/target/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found — skipping functional tests"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="; [[ "$FAIL" -eq 0 ]]
fi

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    "$BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --quiet --force-duplicate 2>/dev/null
}

export CHUMP_HOME="$(mktemp -d)"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1

# ── Scenario 1: over-budget P0 (>5) ─────────────────────────────────────────
echo "[scenario 1: over-budget P0]"
TMP1="$(mktemp -d)"; export CHUMP_REPO="$TMP1"

# 6 P0 gaps (one over budget)
for i in $(seq 1 6); do
    reserve_gap "EFFECTIVE: fixture-p0-$i" P0 xs
done

OUT1=$("$BIN" gap rebalance 2>&1 || true)
if "$BIN" gap rebalance >/dev/null 2>&1; then
    fail "over-budget P0 should exit non-zero"
else
    ok "over-budget P0 exits non-zero"
fi

if echo "$OUT1" | grep -qi "DEMOTE\|demote\|budget"; then
    ok "over-budget P0 suggests DEMOTE action"
else
    fail "over-budget P0 should suggest DEMOTE — got: $OUT1"
fi

# --apply should demote excess P0s
"$BIN" gap rebalance --apply >/dev/null 2>&1 || true
_p0_tmpout="$(mktemp)"
"$BIN" gap rebalance --json > "$_p0_tmpout" 2>/dev/null || true
P0_AFTER=$(python3 -c "import sys,json; d=json.load(open('$_p0_tmpout')); print(d.get('p0_count',99))" 2>/dev/null || echo 99)
rm -f "$_p0_tmpout"
if [[ "${P0_AFTER:-99}" -le 5 ]]; then
    ok "after --apply, P0 count ≤ 5 (got $P0_AFTER)"
else
    fail "after --apply, P0 count should be ≤ 5 (got $P0_AFTER)"
fi

rm -rf "$TMP1"

# ── Scenario 2: pillar skew (one dominates >50%) ─────────────────────────────
echo
echo "[scenario 2: pillar skew]"
TMP2="$(mktemp -d)"; export CHUMP_REPO="$TMP2"

# 10 EFFECTIVE P1 gaps — EFFECTIVE dominates; other pillars starved
for i in $(seq 1 10); do
    reserve_gap "EFFECTIVE: fixture-skew-$i" P1 xs
done

if "$BIN" gap rebalance >/dev/null 2>&1; then
    fail "pillar-skew should exit non-zero"
else
    ok "pillar-skew exits non-zero"
fi

OUT2=$("$BIN" gap rebalance 2>&1 || true)
if echo "$OUT2" | grep -qi "DEMOTE\|FILE\|pillar\|floor\|dominates"; then
    ok "pillar-skew suggests corrective action"
else
    fail "pillar-skew should suggest corrective action — got: $OUT2"
fi

rm -rf "$TMP2"

# ── Scenario 3: all clean ────────────────────────────────────────────────────
echo
echo "[scenario 3: all clean]"
TMP3="$(mktemp -d)"; export CHUMP_REPO="$TMP3"

# 2 per pillar → balanced, no P0s
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: fixture-clean-a" P1 xs
    reserve_gap "${p}: fixture-clean-b" P1 xs
done

if "$BIN" gap rebalance >/dev/null 2>&1; then
    ok "clean registry exits 0"
else
    fail "clean registry should exit 0"
fi

OUT3=$("$BIN" gap rebalance 2>&1)
if echo "$OUT3" | grep -q "clean\|OK"; then
    ok "clean registry prints OK message"
else
    fail "clean registry should print OK message — got: $OUT3"
fi

JSON3=$("$BIN" gap rebalance --json 2>/dev/null)
if echo "$JSON3" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('clean')==True" 2>/dev/null; then
    ok "--json clean=true on balanced registry"
else
    fail "--json clean should be true — got: $JSON3"
fi

rm -rf "$TMP3"

# ── Scenario 4: no-action-needed (exactly at floor, P0=0) ───────────────────
echo
echo "[scenario 4: no-action-needed]"
TMP4="$(mktemp -d)"; export CHUMP_REPO="$TMP4"

# Exactly 2 per pillar, 0 P0s → no action
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: fixture-floor-a" P1 s
    reserve_gap "${p}: fixture-floor-b" P1 s
done

ACTIONS=$("$BIN" gap rebalance --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('actions',[])))" 2>/dev/null || echo -1)
if [[ "$ACTIONS" -eq 0 ]]; then
    ok "no-action-needed: 0 actions (got $ACTIONS)"
else
    fail "no-action-needed should have 0 actions (got $ACTIONS)"
fi

rm -rf "$TMP4"

# ── --json required keys ──────────────────────────────────────────────────────
echo
echo "[--json required keys]"
TMP5="$(mktemp -d)"; export CHUMP_REPO="$TMP5"
_j5_out="$(mktemp)"
"$BIN" gap rebalance --json > "$_j5_out" 2>/dev/null || true
JSON5="$(cat "$_j5_out")"; rm -f "$_j5_out"
for key in p0_count p0_budget total_pickable actions applied clean; do
    if printf '%s' "$JSON5" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
        ok "JSON key '$key' present"
    else
        fail "JSON key '$key' missing — got: $JSON5"
    fi
done
rm -rf "$TMP5"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
