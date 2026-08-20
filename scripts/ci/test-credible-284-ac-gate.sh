#!/usr/bin/env bash
# test-credible-284-ac-gate.sh — CREDIBLE-284
#
# Proves the P0/P1 acceptance-criteria gate on `chump gap reserve` actually
# bites (stops the tautological placeholder), that authored AC is stored
# verbatim, and that `chump gap decompose` never overwrites the parent's
# authored acceptance_criteria field.
#
# Cases:
#   (a) P1 reserve WITHOUT --acceptance-criteria       → BLOCKED (exit 1)
#   (b) P1 reserve WITH --acceptance-criteria           → SUCCEEDS, AC stored verbatim
#   (c) P2 reserve WITHOUT --acceptance-criteria         → SUCCEEDS (gate only P0/P1),
#       AC is EMPTY (no tautological placeholder auto-filled)
#   (d) --no-ac-required bypass                          → SUCCEEDS + audited ac_gate_bypassed
#   (e) chump gap decompose leaves authored parent AC unchanged (static source check —
#       the parent GapFieldUpdate on --apply must not set acceptance_criteria)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== CREDIBLE-284 acceptance-criteria gate test ==="
echo

# ── Static source checks ─────────────────────────────────────────────────────

if grep -q 'no_ac_required' "$REPO_ROOT/src/main.rs"; then
    ok "no_ac_required flag wired in main.rs"
else
    fail "no_ac_required flag not found in main.rs"
fi

if grep -q '\-\-no-ac-required' "$REPO_ROOT/src/main.rs"; then
    ok "--no-ac-required bypass flag wired in main.rs"
else
    fail "--no-ac-required bypass flag not found in main.rs"
fi

if grep -q 'ac_gate_bypassed' "$REPO_ROOT/src/main.rs"; then
    ok "ac_gate_bypassed emitted in main.rs"
else
    fail "ac_gate_bypassed not found in main.rs"
fi

if grep -q 'ac_gate_bypassed' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt"; then
    ok "ac_gate_bypassed registered in event-registry-reserved.txt"
else
    fail "ac_gate_bypassed missing from event-registry-reserved.txt"
fi

# CREDIBLE-284 AC2: reserve must NOT auto-fill the tautological placeholder
# anymore. default_acceptance_criteria() must no longer be called from the
# `"reserve" =>` arm of `chump gap`.
RESERVE_ARM=$(awk '/^            "reserve" => \{/{flag=1} flag{print} /^            "claim" => \{/{if(flag)exit}' "$REPO_ROOT/src/main.rs")
if echo "$RESERVE_ARM" | grep -q 'default_acceptance_criteria'; then
    fail "reserve arm still calls default_acceptance_criteria (tautological placeholder not removed)"
else
    ok "reserve arm no longer calls default_acceptance_criteria"
fi

# CREDIBLE-284 AC3: decompose's parent-demotion GapFieldUpdate must not set
# acceptance_criteria (the authored done-definition is never overwritten).
DECOMPOSE_PARENT_UPDATE=$(awk '/Demote parent to P2/{flag=1} flag{print; if(/^                    \);$/){exit}}' "$REPO_ROOT/src/main.rs" | grep -v '^\s*//')
if echo "$DECOMPOSE_PARENT_UPDATE" | grep -q 'acceptance_criteria: Some'; then
    fail "decompose parent-demotion update sets acceptance_criteria (would overwrite authored AC)"
else
    ok "decompose parent-demotion update does not touch acceptance_criteria"
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

# Fixture outcome so MISSION-045's separate outcome gate doesn't block these
# P0/P1 reserves — this test is scoped to the AC gate only.
"$BIN" outcome new --id ACGATEOUT --title "ac-gate fixture outcome" >/dev/null 2>&1 || true

# (a) P1 without --acceptance-criteria → BLOCKED
echo
echo "--- (a) P1 without --acceptance-criteria ---"
ERR_OUT=$(
    "$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
        --title "test-ac-gate-a" --outcome ACGATEOUT 2>&1 || true
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

# (b) P1 with --acceptance-criteria → SUCCEEDS, stored verbatim
echo
echo "--- (b) P1 with --acceptance-criteria ---"
B_ID=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "test-ac-gate-b" --outcome ACGATEOUT \
    --acceptance-criteria "first bullet must hold|second bullet must hold" \
    --quiet 2>/dev/null || true)
if [[ -n "$B_ID" ]]; then
    ok "(b) P1 with --acceptance-criteria reserved successfully (id=$B_ID)"
else
    fail "(b) P1 with --acceptance-criteria failed to reserve"
fi
if [[ -n "$B_ID" ]]; then
    SHOW_OUT=$("$BIN" gap show "$B_ID" 2>/dev/null || true)
    if echo "$SHOW_OUT" | grep -q "first bullet must hold" && echo "$SHOW_OUT" | grep -q "second bullet must hold"; then
        ok "(b) authored AC stored verbatim, shown in gap show"
    else
        fail "(b) authored AC not found verbatim in gap show output (show=$SHOW_OUT)"
    fi
    if echo "$SHOW_OUT" | grep -qi "is implemented in the relevant"; then
        fail "(b) tautological placeholder AC leaked into authored gap"
    else
        ok "(b) no tautological placeholder present"
    fi
fi

# (c) P2 without --acceptance-criteria → SUCCEEDS, AC is EMPTY (no placeholder)
echo
echo "--- (c) P2 without --acceptance-criteria ---"
C_ID=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "test-ac-gate-c" \
    --quiet 2>/dev/null || true)
if [[ -n "$C_ID" ]]; then
    ok "(c) P2 without --acceptance-criteria reserved (gate only applies P0/P1)"
    SHOW_OUT=$("$BIN" gap show "$C_ID" 2>/dev/null || true)
    if echo "$SHOW_OUT" | grep -qi "is implemented in the relevant"; then
        fail "(c) tautological placeholder AC was auto-filled (should be empty)"
    else
        ok "(c) no tautological placeholder auto-filled — AC left empty"
    fi
else
    fail "(c) P2 without --acceptance-criteria should succeed"
fi

# (d) --no-ac-required bypass → SUCCEEDS + audited ac_gate_bypassed
echo
echo "--- (d) bypass via --no-ac-required ---"
D_ID=$("$BIN" gap reserve --domain INFRA --priority P0 --effort xs \
    --title "test-ac-gate-d" --outcome ACGATEOUT \
    --no-ac-required \
    --quiet 2>/dev/null || true)
if [[ -n "$D_ID" ]]; then
    ok "(d) P0 with --no-ac-required succeeded — gap reserved"
else
    fail "(d) bypass via --no-ac-required did not reserve gap"
fi
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"ac_gate_bypassed"' "$AMBIENT"; then
    ok "(d) ac_gate_bypassed event emitted to ambient.jsonl"
else
    fail "(d) ac_gate_bypassed event NOT found in ambient.jsonl"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
