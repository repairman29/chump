#!/usr/bin/env bash
# test-ac-gate.sh — CREDIBLE-284
#
# Proves the P0/P1 acceptance-criteria gate on `chump gap reserve` actually
# BITES (refuses an unauthored P0/P1 gap instead of silently minting the old
# tautological placeholder), that authored AC is stored verbatim, and that
# `chump gap decompose` never overwrites a parent's authored AC.
#
# Cases:
#   1. P1 reserve WITHOUT --acceptance-criteria (outcome gate bypassed)  → BLOCKED (exit 1)
#   2. P0 reserve WITHOUT --acceptance-criteria                          → BLOCKED (exit 1)
#   3. P1 reserve WITH --acceptance-criteria "..."                      → SUCCEEDS, AC stored verbatim
#   4. P0 reserve WITH --no-ac-required                                 → SUCCEEDS + audited ac_gate_bypassed, AC empty
#   5. P2 reserve WITHOUT --acceptance-criteria                         → SUCCEEDS (permissionless)
#   6. decompose (simulated parent-demote step) leaves authored AC unchanged

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== CREDIBLE-284 acceptance-criteria gate test ==="
echo

# ── Source checks (static, no binary needed) ──────────────────────────────────

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

if grep -q '\-\-no-ac-required' "$REPO_ROOT/src/main.rs"; then
    ok "--no-ac-required bypass flag wired in main.rs"
else
    fail "--no-ac-required not found in main.rs"
fi

if grep -q 'fn default_acceptance_criteria' "$REPO_ROOT/src/main.rs"; then
    fail "default_acceptance_criteria() autofill still present — placeholder should be removed"
else
    ok "default_acceptance_criteria() autofill removed"
fi

# The decompose --apply block must only set acceptance_criteria on the newly
# filed sub-gap id (new_id), never on the parent's gap_id.
if awk '/if apply \{/,/^                \}$/' "$REPO_ROOT/src/main.rs" \
    | grep -B4 'acceptance_criteria: Some(ac_json)' \
    | grep -q '&new_id'; then
    ok "decompose --apply sets acceptance_criteria only on filed sub-gap id"
else
    fail "could not confirm decompose --apply scopes acceptance_criteria writes to sub-gap id"
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
export CHUMP_HOME="$TMP"
export CHUMP_REPO="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_EVIDENCE=1
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/.chump-locks/ambient.jsonl"

reserve() {  # priority effort title extra-args...
    local priority="$1" effort="$2" title="$3"; shift 3
    "$BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --quiet --force-duplicate --no-outcome-required "$@"
}

# 1. P1 without --acceptance-criteria → BLOCKED
if reserve P1 xs "ac-gate-case1" >/dev/null 2>&1; then
    fail "case 1: P1 without --acceptance-criteria should be BLOCKED"
else
    ok "case 1: P1 without --acceptance-criteria is blocked"
fi

# 2. P0 without --acceptance-criteria → BLOCKED
if reserve P0 xs "ac-gate-case2" >/dev/null 2>&1; then
    fail "case 2: P0 without --acceptance-criteria should be BLOCKED"
else
    ok "case 2: P0 without --acceptance-criteria is blocked"
fi

# 3. P1 with --acceptance-criteria → SUCCEEDS, AC stored verbatim
GAP3=$(reserve P1 xs "ac-gate-case3" --acceptance-criteria "first bullet|second bullet" 2>&1 | grep -Eo 'INFRA-[0-9]+' | head -1)
if [[ -n "${GAP3:-}" ]]; then
    ok "case 3: P1 with --acceptance-criteria succeeds ($GAP3)"
    STORED=$("$BIN" gap show "$GAP3" --field acceptance_criteria 2>/dev/null || true)
    if [[ "$STORED" == *"first bullet"* && "$STORED" == *"second bullet"* ]]; then
        ok "case 3: AC stored verbatim"
    else
        fail "case 3: stored AC does not match authored input: $STORED"
    fi
else
    fail "case 3: P1 with --acceptance-criteria should succeed"
fi

# 4. P0 with --no-ac-required → SUCCEEDS + audited ac_gate_bypassed, AC empty
GAP4=$(reserve P0 xs "ac-gate-case4" --no-ac-required 2>&1 | grep -Eo 'INFRA-[0-9]+' | head -1)
if [[ -n "${GAP4:-}" ]]; then
    ok "case 4: P0 with --no-ac-required succeeds ($GAP4)"
    if grep -q '"kind":"ac_gate_bypassed"' "$AMBIENT" 2>/dev/null; then
        ok "case 4: bypass emitted audited ac_gate_bypassed event"
    else
        fail "case 4: --no-ac-required must emit ac_gate_bypassed"
    fi
    STORED4=$("$BIN" gap show "$GAP4" --field acceptance_criteria 2>/dev/null || true)
    if [[ -z "$STORED4" || "$STORED4" == "[]" ]]; then
        ok "case 4: bypassed gap has EMPTY AC (no tautological placeholder)"
    else
        fail "case 4: bypassed gap should have empty AC, got: $STORED4"
    fi
else
    fail "case 4: P0 with --no-ac-required should succeed"
fi

# 5. P2 without --acceptance-criteria → SUCCEEDS (permissionless)
if reserve P2 xs "ac-gate-case5" >/dev/null 2>&1; then
    ok "case 5: P2 without AC is permissionless"
else
    fail "case 5: P2 without AC should succeed (permissionless)"
fi

# 6. decompose leaves authored AC unchanged: reserve a parent with AC, run
# the same field-update decompose --apply performs on a PARENT (priority +
# notes only, per src/main.rs) via `chump gap set`, and confirm the AC field
# is untouched.
GAP6=$(reserve P1 m "ac-gate-case6-parent" --acceptance-criteria "the fixed done-definition" 2>&1 | grep -Eo 'INFRA-[0-9]+' | head -1)
if [[ -n "${GAP6:-}" ]]; then
    "$BIN" gap set "$GAP6" --priority P2 --notes "Decomposed into 2 slices: X, Y" >/dev/null 2>&1 || true
    STORED6=$("$BIN" gap show "$GAP6" --field acceptance_criteria 2>/dev/null || true)
    if [[ "$STORED6" == *"the fixed done-definition"* ]]; then
        ok "case 6: parent demote (priority+notes) leaves authored AC unchanged"
    else
        fail "case 6: parent AC changed after demote: $STORED6"
    fi
else
    fail "case 6: could not reserve fixture parent gap"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
