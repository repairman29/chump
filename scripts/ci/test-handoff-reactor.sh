#!/usr/bin/env bash
# scripts/ci/test-handoff-reactor.sh — META-170: smoke test for Phase 1.5
# react-feedback reactor in scripts/coord/handoff-loop.sh.
#
# Three fixtures per AC #5:
#   1. Well-formed MissionLeadContract proposal → assert vote +1
#   2. Schema-missing-Validate proposal          → assert vote -1
#   3. Overlapping existing DecomposeContract    → assert vote 0

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/handoff-loop.sh"

if [[ ! -x "$LOOP_SCRIPT" ]]; then
    echo "FAIL: $LOOP_SCRIPT not found or not executable" >&2
    exit 1
fi

_pass=0
_fail=0

_ok()  { echo "  ok  $*"; _pass=$((_pass + 1)); }
_bad() { echo "  FAIL: $*" >&2; _fail=$((_fail + 1)); }

# Helper: run react-feedback with a fresh ambient log + no cooldown files,
# returns the ambient log path via stdout (caller captures).
# Usage: _run_fixture <corr_id> <rationale> → stdout = ambient file path; side-effect = ambient written
_run_fixture() {
    local corr_id="$1"
    local rationale="$2"
    local tmpdir
    tmpdir="$(mktemp -d)"
    local amb="$tmpdir/ambient.jsonl"

    # Use tmpdir as LOCK_DIR so cooldown files land there too and don't persist.
    CHUMP_FLEET_WIRE_V1=1 \
    CHUMP_AMBIENT_LOG="$amb" \
    CHUMP_SESSION_ID="test-reactor-$$" \
    LOCK_DIR="$tmpdir" \
    "$LOOP_SCRIPT" react-feedback "$corr_id" "$rationale" >/dev/null 2>&1 || true

    # Caller reads the ambient file directly; echo path so caller can clean up.
    printf '%s\n' "$tmpdir"
}

# ── Fixture 1: well-formed MissionLeadContract → vote +1 ─────────────────────
echo "Fixture 1: well-formed MissionLeadContract proposal..."
RATIONALE_1="Proposing MissionLeadContract in contracts.rs. It has Input struct for mission params, Output struct for lead results, implements Validate for semantic checks, has a prompt() template that instructs the subagent on output shape, and selects ModelTier::Sonnet for execution work."

tmpdir1="$(_run_fixture "corr-fixture-1-$$" "$RATIONALE_1")"
amb1="$tmpdir1/ambient.jsonl"

if grep -q '"kind":"handoff_contract_vote"' "$amb1" 2>/dev/null; then
    _ok "fixture 1: handoff_contract_vote emitted"
else
    _bad "fixture 1: no handoff_contract_vote in ambient"
fi

if grep -q '"vote":1' "$amb1" 2>/dev/null; then
    _ok "fixture 1: vote is +1 (well-formed schema)"
else
    _bad "fixture 1: expected vote=1, got: $(grep 'handoff_contract_vote' "$amb1" 2>/dev/null || echo '(nothing)')"
fi

if grep -q 'MissionLeadContract' "$amb1" 2>/dev/null; then
    _ok "fixture 1: proposed contract name recorded in reason"
else
    _bad "fixture 1: MissionLeadContract not found in ambient emit"
fi

rm -rf "$tmpdir1"

# ── Fixture 2: schema-missing-Validate → vote -1 ─────────────────────────────
echo "Fixture 2: schema-incomplete proposal (missing Validate)..."
RATIONALE_2="Proposing TelemetryContract in contracts.rs. It has Input struct for telemetry params, Output struct for the gathered metrics, has a prompt() template describing output JSON, and selects ModelTier::Haiku for lightweight work."
# NOTE: deliberately omits "Validate"

tmpdir2="$(_run_fixture "corr-fixture-2-$$" "$RATIONALE_2")"
amb2="$tmpdir2/ambient.jsonl"

if grep -q '"kind":"handoff_contract_vote"' "$amb2" 2>/dev/null; then
    _ok "fixture 2: handoff_contract_vote emitted"
else
    _bad "fixture 2: no handoff_contract_vote in ambient"
fi

if grep -q '"vote":-1' "$amb2" 2>/dev/null; then
    _ok "fixture 2: vote is -1 (schema incomplete)"
else
    _bad "fixture 2: expected vote=-1, got: $(grep 'handoff_contract_vote' "$amb2" 2>/dev/null || echo '(nothing)')"
fi

if grep -q 'Validate' "$amb2" 2>/dev/null; then
    _ok "fixture 2: missing field 'Validate' named in reason"
else
    _bad "fixture 2: 'Validate' not mentioned in reason"
fi

rm -rf "$tmpdir2"

# ── Fixture 3: overlapping existing DecomposeContract → vote 0 ───────────────
echo "Fixture 3: overlapping existing DecomposeContract → vote 0..."
RATIONALE_3="Proposing DecomposeContract in contracts.rs. It has Input struct for gap decompose params, Output struct for sub-gap list, implements Validate for topological checks, has a prompt() template for Opus, and selects ModelTier::Opus."
# NOTE: DecomposeContract already exists in crates/chump-handoff/src/contracts.rs

tmpdir3="$(_run_fixture "corr-fixture-3-$$" "$RATIONALE_3")"
amb3="$tmpdir3/ambient.jsonl"

if grep -q '"kind":"handoff_contract_vote"' "$amb3" 2>/dev/null; then
    _ok "fixture 3: handoff_contract_vote emitted"
else
    _bad "fixture 3: no handoff_contract_vote in ambient"
fi

if grep -q '"vote":0' "$amb3" 2>/dev/null; then
    _ok "fixture 3: vote is 0 (overlaps existing)"
else
    _bad "fixture 3: expected vote=0, got: $(grep 'handoff_contract_vote' "$amb3" 2>/dev/null || echo '(nothing)')"
fi

if grep -q 'overlaps existing' "$amb3" 2>/dev/null; then
    _ok "fixture 3: 'overlaps existing' hint in reason"
else
    _bad "fixture 3: overlap hint not found in reason"
fi

rm -rf "$tmpdir3"

# ── Cooldown guard ────────────────────────────────────────────────────────────
echo "Cooldown: re-voting same corr_id within 1h should be skipped..."
CORR_COOLDOWN="corr-cooldown-$$"
RATIONALE_GOOD="Proposing CooldownTestContract in contracts.rs with Input, Output, Validate, prompt, and ModelTier all present."

# First vote should land.
tmpdir_cd="$(mktemp -d)"
amb_cd="$tmpdir_cd/ambient.jsonl"
CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$amb_cd" \
CHUMP_SESSION_ID="test-reactor-$$" \
LOCK_DIR="$tmpdir_cd" \
"$LOOP_SCRIPT" react-feedback "$CORR_COOLDOWN" "$RATIONALE_GOOD" >/dev/null 2>&1 || true

vote_count1="$(grep -c '"kind":"handoff_contract_vote"' "$amb_cd" 2>/dev/null || echo 0)"

# Second vote (same corr_id, same tmpdir with cooldown file) should be skipped.
CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$amb_cd" \
CHUMP_SESSION_ID="test-reactor-$$" \
LOCK_DIR="$tmpdir_cd" \
"$LOOP_SCRIPT" react-feedback "$CORR_COOLDOWN" "$RATIONALE_GOOD" >/dev/null 2>&1 || true

vote_count2="$(grep -c '"kind":"handoff_contract_vote"' "$amb_cd" 2>/dev/null || echo 0)"

if (( vote_count1 == 1 && vote_count2 == 1 )); then
    _ok "cooldown: second vote suppressed (still 1 vote event)"
else
    _bad "cooldown: expected 1 vote after two calls, got vote_count1=${vote_count1} vote_count2=${vote_count2}"
fi

# Cooldown skip event should appear on second call.
if grep -q '"kind":"handoff_reactor_cooldown_skip"' "$amb_cd" 2>/dev/null; then
    _ok "cooldown: handoff_reactor_cooldown_skip emitted on repeat call"
else
    _bad "cooldown: handoff_reactor_cooldown_skip not found"
fi

rm -rf "$tmpdir_cd"

# ── Feature flag gate ─────────────────────────────────────────────────────────
echo "Feature flag: CHUMP_FLEET_WIRE_V1=0 should skip react-feedback..."
tmpdir_ff="$(mktemp -d)"
amb_ff="$tmpdir_ff/ambient.jsonl"
rc_ff=0
CHUMP_FLEET_WIRE_V1=0 \
CHUMP_AMBIENT_LOG="$amb_ff" \
CHUMP_SESSION_ID="test-reactor-ff-$$" \
LOCK_DIR="$tmpdir_ff" \
"$LOOP_SCRIPT" react-feedback "corr-ff-$$" "Proposing FlaggedContract with Input Output Validate prompt ModelTier" \
    >/dev/null 2>&1 || rc_ff=$?

if (( rc_ff == 1 )); then
    _ok "feature flag: exits 1 when CHUMP_FLEET_WIRE_V1=0"
else
    _bad "feature flag: expected exit 1, got $rc_ff"
fi

if ! grep -q '"kind":"handoff_contract_vote"' "$amb_ff" 2>/dev/null; then
    _ok "feature flag: no vote emitted when gated off"
else
    _bad "feature flag: vote should not be emitted when CHUMP_FLEET_WIRE_V1=0"
fi
rm -rf "$tmpdir_ff"

# ── Scanner-anchor discipline ─────────────────────────────────────────────────
echo "Scanner-anchor: new kind tags must have anchor comments..."
if grep -q '# scanner-anchor: "kind":"handoff_contract_vote"' "$LOOP_SCRIPT"; then
    _ok "handoff_contract_vote has scanner-anchor"
else
    _bad "handoff_contract_vote missing scanner-anchor comment in $LOOP_SCRIPT"
fi
if grep -q '# scanner-anchor: "kind":"handoff_reactor_cooldown_skip"' "$LOOP_SCRIPT"; then
    _ok "handoff_reactor_cooldown_skip has scanner-anchor"
else
    _bad "handoff_reactor_cooldown_skip missing scanner-anchor comment in $LOOP_SCRIPT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: ${_pass} passed, ${_fail} failed"
if (( _fail > 0 )); then
    exit 1
fi
echo "ok all test-handoff-reactor tests passed"
