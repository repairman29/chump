#!/usr/bin/env bash
# test-credible-284-ac-firewall.sh — CREDIBLE-284
#
# Validates the --acceptance-criteria intake firewall on `chump gap reserve`
# and that `chump gap decompose` never overwrites an authored parent AC.
#
# Test cases:
#  (a) P1 reserve without --acceptance-criteria → refused with documented message
#  (b) P1 reserve with --acceptance-criteria → succeeds, AC stored verbatim
#  (c) P2 reserve without --acceptance-criteria → succeeds (gate only P0/P1),
#      and the gap's AC is genuinely empty — not the old tautological placeholder
#  (d) --no-ac-required bypasses the P1 gate, emits gap_reserved_no_ac
#  (e) source check: `chump gap decompose --apply` only ever writes
#      priority/notes onto the *parent* gap, never acceptance_criteria — so an
#      authored parent AC survives decomposition unchanged (the WHAT is fixed,
#      only the HOW/sub-slices are generated)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== CREDIBLE-284 acceptance-criteria firewall test ==="
echo

# ── Source checks (static, no binary needed) ──────────────────────────────────

if grep -q 'gap_reserved_no_ac' "$REPO_ROOT/src/main.rs"; then
    ok "gap_reserved_no_ac emitted in main.rs"
else
    fail "gap_reserved_no_ac not found in main.rs"
fi

if grep -q -- '--no-ac-required' "$REPO_ROOT/src/main.rs"; then
    ok "--no-ac-required bypass flag wired in main.rs"
else
    fail "--no-ac-required not found in main.rs"
fi

if grep -q 'The change described by' "$REPO_ROOT/src/main.rs"; then
    fail "tautological placeholder text still present in main.rs"
else
    ok "tautological placeholder text removed from main.rs"
fi

if grep -q 'default_acceptance_criteria' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/web_server.rs"; then
    fail "default_acceptance_criteria auto-fill still referenced"
else
    ok "default_acceptance_criteria auto-fill removed"
fi

# (e) decompose must never write acceptance_criteria onto the parent gap.
# Extract the "Demote parent to P2" set_fields block and assert it has no
# acceptance_criteria field — the parent's authored AC (the WHAT) is fixed;
# decompose only ever generates sub-gaps (the HOW).
DEMOTE_BLOCK="$(awk '/\/\/ Demote parent to P2/,/^                    \);/' "$REPO_ROOT/src/main.rs")"
if [[ -n "$DEMOTE_BLOCK" ]] && ! echo "$DEMOTE_BLOCK" | grep -q 'acceptance_criteria'; then
    ok "(e) decompose's parent-demote set_fields never touches acceptance_criteria"
else
    fail "(e) decompose's parent-demote block missing or touches acceptance_criteria (got: $DEMOTE_BLOCK)"
fi

# ── Functional tests ──────────────────────────────────────────────────────────

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    RUSTC_WRAPPER="" cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

TMP="$(mktemp -d)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_EVIDENCE=1

# (a) P1 without --acceptance-criteria → must fail with documented message
echo
echo "--- (a) P1 without --acceptance-criteria ---"
ERR_OUT=$(
    "$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
        --no-outcome-required \
        --title "test-ac-gate-a" 2>&1 || true
)
if echo "$ERR_OUT" | grep -q "require --acceptance-criteria"; then
    ok "(a) gate fires: refused with documented message"
else
    fail "(a) gate did not fire for P1 without --acceptance-criteria (got: $ERR_OUT)"
fi
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-ac-gate-a" || true)
if [[ "$CNT" -eq 0 ]]; then
    ok "(a) gap was NOT reserved (gate blocked correctly)"
else
    fail "(a) gap was reserved despite gate (should have been blocked)"
fi

# (b) P1 with --acceptance-criteria → succeeds, AC stored verbatim
echo
echo "--- (b) P1 with --acceptance-criteria ---"
B_ID=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --no-outcome-required \
    --title "test-ac-gate-b" \
    --acceptance-criteria "the widget renders|the widget is clickable" \
    --quiet 2>/dev/null || true)
if [[ -n "$B_ID" ]]; then
    ok "(b) P1 with --acceptance-criteria reserved successfully (id=$B_ID)"
else
    fail "(b) P1 with --acceptance-criteria failed to reserve"
fi
if [[ -n "$B_ID" ]]; then
    SHOW_OUT=$("$BIN" gap show "$B_ID" 2>/dev/null || true)
    if echo "$SHOW_OUT" | grep -q "the widget renders" && echo "$SHOW_OUT" | grep -q "the widget is clickable"; then
        ok "(b) AC text stored verbatim and shown in gap show"
    else
        fail "(b) AC not found verbatim in gap show output (show=$SHOW_OUT)"
    fi
fi

# (c) P2 without --acceptance-criteria → succeeds, AC genuinely empty
echo
echo "--- (c) P2 without --acceptance-criteria ---"
C_ID=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "test-ac-gate-c" \
    --quiet 2>/dev/null || true)
if [[ -n "$C_ID" ]]; then
    ok "(c) P2 without --acceptance-criteria allowed (gate only applies P0/P1)"
else
    fail "(c) P2 was blocked — gate should not apply to P2"
fi
if [[ -n "$C_ID" ]]; then
    DB="$TMP/.chump/state.db"
    AC_VAL=$(sqlite3 "$DB" "SELECT acceptance_criteria FROM gaps WHERE id='$C_ID'" 2>/dev/null || echo "")
    if [[ "$AC_VAL" == "[]" || -z "$AC_VAL" ]]; then
        ok "(c) unauthored gap has genuinely empty AC (got: '$AC_VAL')"
    else
        fail "(c) unauthored gap AC should be empty, got tautological/placeholder text: '$AC_VAL'"
    fi
fi

# (d) --no-ac-required bypasses gate, emits gap_reserved_no_ac
echo
echo "--- (d) bypass via --no-ac-required ---"
"$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --no-outcome-required \
    --no-ac-required \
    --title "test-ac-gate-d" \
    --quiet 2>/dev/null
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-ac-gate-d" || true)
if [[ "$CNT" -ge 1 ]]; then
    ok "(d) bypass via --no-ac-required succeeded — gap reserved"
else
    fail "(d) bypass via --no-ac-required did not reserve gap"
fi
if [[ -f "$AMBIENT" ]] && grep -q "gap_reserved_no_ac" "$AMBIENT"; then
    ok "(d) gap_reserved_no_ac event emitted to ambient.jsonl"
else
    fail "(d) gap_reserved_no_ac event NOT found in ambient.jsonl"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
