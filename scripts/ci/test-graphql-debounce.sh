#!/usr/bin/env bash
# scripts/ci/test-graphql-debounce.sh — INFRA-1968
#
# Regression test for _chump_gh_maybe_emit_exhausted debounce behaviour when
# GitHub returns resets_at:unknown.
#
# Scenarios:
#   1. resets_at known → emits ONCE per reset window (existing behaviour)
#   2. resets_at unknown (0) → emits ONCE; second call within 60s is suppressed
#   3. resets_at unknown → second call after debounce window expires does re-emit
#
# Run from repo root: bash scripts/ci/test-graphql-debounce.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAIL=$(( FAIL + 1 )); }

# ── harness helpers ────────────────────────────────────────────────────────

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Source the library in a subshell so we can call _chump_gh_maybe_emit_exhausted
# directly with a controlled ambient path and flag state.
call_maybe_emit() {
    # $1 = gql_rem, $2 = resets_at, $3 = ambient_path
    # Runs _chump_gh_maybe_emit_exhausted in a subprocess so the flag file
    # it writes persists in the SANDBOX but env isolation is clean.
    local gql_rem="$1" resets_at="$2" ambient="$3"
    bash -c "
set -uo pipefail
source '$REPO_ROOT/scripts/coord/lib/github.sh' 2>/dev/null || true
export CHUMP_AMBIENT_OVERRIDE='$ambient'
export CHUMP_GH_SILENT=1
# Unset PATH-inject to avoid real gh invocations
export CHUMP_GH_NO_PATH_INJECT=1
_chump_gh_maybe_emit_exhausted '$gql_rem' '$resets_at' '$ambient'
"
}

count_exhausted_events() {
    local ambient="$1"
    local n
    n="$(grep -c '"kind":"graphql_exhausted"' "$ambient" 2>/dev/null)" || n=0
    printf '%s' "$n"
}

# ── Test 1: known resets_at — emits once, second call within window suppressed ─

T1_DIR="$SANDBOX/t1"
mkdir -p "$T1_DIR"
T1_AMB="$T1_DIR/ambient.jsonl"
touch "$T1_AMB"

future_reset=$(( $(date +%s) + 3600 ))   # 1h from now

call_maybe_emit 50 "$future_reset" "$T1_AMB"
call_maybe_emit 50 "$future_reset" "$T1_AMB"
call_maybe_emit 10 "$future_reset" "$T1_AMB"

count=$(count_exhausted_events "$T1_AMB")
if [[ "$count" -eq 1 ]]; then
    pass "known resets_at: emits exactly 1 event for 3 rapid calls"
else
    fail "known resets_at: expected 1 event, got $count"
fi

# ── Test 2: unknown resets_at (0) — emits once, second rapid call suppressed ──
# This is the INFRA-1968 regression case.

T2_DIR="$SANDBOX/t2"
mkdir -p "$T2_DIR"
T2_AMB="$T2_DIR/ambient.jsonl"
touch "$T2_AMB"

# Simulate the 2026-05-24 cascade: 6 rapid calls with resets_at=0 (unknown).
for i in 1 2 3 4 5 6; do
    call_maybe_emit 50 "0" "$T2_AMB"
done

count=$(count_exhausted_events "$T2_AMB")
if [[ "$count" -eq 1 ]]; then
    pass "resets_at:unknown — 6 rapid calls produce exactly 1 emit (INFRA-1968 regression)"
else
    fail "resets_at:unknown — expected 1 emit, got $count (INFRA-1968 cascade not fixed)"
fi

# ── Test 3: unknown resets_at — re-emits after debounce window expires ─────────

T3_DIR="$SANDBOX/t3"
mkdir -p "$T3_DIR"
T3_AMB="$T3_DIR/ambient.jsonl"
touch "$T3_AMB"

FLAG="$T3_DIR/.graphql-exhausted-since"

# First call emits, writes flag with (now + 60).
call_maybe_emit 50 "0" "$T3_AMB"

# Simulate expiry: write a past epoch to the flag (simulates 61+ seconds elapsed).
past_epoch=$(( $(date +%s) - 1 ))
printf '%s' "$past_epoch" > "$FLAG"

# Second call should now re-emit because the debounce window has expired.
call_maybe_emit 50 "0" "$T3_AMB"

count=$(count_exhausted_events "$T3_AMB")
if [[ "$count" -eq 2 ]]; then
    pass "resets_at:unknown — re-emits after debounce window expires"
else
    fail "resets_at:unknown — expected 2 emits after window expiry, got $count"
fi

# ── Test 4: resets_at absent/empty treated same as unknown ───────────────────

T4_DIR="$SANDBOX/t4"
mkdir -p "$T4_DIR"
T4_AMB="$T4_DIR/ambient.jsonl"
touch "$T4_AMB"

# Call three times with empty string resets_at.
for i in 1 2 3; do
    call_maybe_emit 50 "" "$T4_AMB"
done

count=$(count_exhausted_events "$T4_AMB")
if [[ "$count" -eq 1 ]]; then
    pass "resets_at:empty — 3 rapid calls produce exactly 1 emit"
else
    fail "resets_at:empty — expected 1 emit, got $count"
fi

# ── Test 5: threshold check — above threshold does not emit ──────────────────

T5_DIR="$SANDBOX/t5"
mkdir -p "$T5_DIR"
T5_AMB="$T5_DIR/ambient.jsonl"
touch "$T5_AMB"

call_maybe_emit 101 "0" "$T5_AMB"
call_maybe_emit 500 "0" "$T5_AMB"
call_maybe_emit 5000 "0" "$T5_AMB"

count=$(count_exhausted_events "$T5_AMB")
if [[ "$count" -eq 0 ]]; then
    pass "above threshold: no emit when gql_rem > 100"
else
    fail "above threshold: expected 0 emits, got $count"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

if [[ "$FAIL" -eq 0 ]]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAIL test(s) FAILED"
    exit 1
fi
