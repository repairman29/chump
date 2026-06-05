#!/usr/bin/env bash
# RESILIENT-061 AC #4: test-deliberator-tick-emits.sh
#
# Scenario A: a proposal whose votes meet quorum + deadline is in the past
#   → asserts kind=consensus_result emitted with the correct verdict (PASSED)
#
# Scenario B: a proposal with a malformed ts (empty, non-ISO, fractional-seconds)
#   → asserts NO crash (exit 0) and NO bogus emission for that corr_id
#
# Scenario C: idempotency — running tick twice on the same resolved proposal
#   → asserts consensus_result count stays at 1 (no double-emit)
#
# Scenario D (RESILIENT-062): a proposal + votes that live ONLY in the durable
#   feedback.jsonl (NOT ambient.jsonl, simulating reaper-pruned ambient) are still
#   seen + tallied → asserts consensus no longer ages out of the audit stream.
#
# Follows the fixture style of scripts/ci/test-chump-consensus-tally.sh.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DELIBERATOR="$REPO_ROOT/scripts/coord/deliberator-loop.sh"

if [[ ! -x "$DELIBERATOR" ]]; then
    echo "[test-deliberator-tick-emits] ERROR: $DELIBERATOR not executable" >&2
    exit 1
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# A past deadline (well outside 48h window) to force a settled verdict.
PAST_DEADLINE="2026-06-01T00:00:00Z"

_run_tick() {
    local ambient="$1"
    # RESILIENT-062: optional 2nd arg = the durable feedback.jsonl the deliberator
    # now scans for proposals/votes. Default to a nonexistent path so _consensus_src
    # falls back to $ambient and the ambient-seeded scenarios (A/B/C) keep working.
    local feedback="${2:-${ambient}.absent-feedback}"
    # tick exits 1 for "quiet" (nothing actionable) — absorb so set -e doesn't abort.
    CHUMP_FLEET_RECV_SIDE_V0=1 CHUMP_AMBIENT_LOG="$ambient" CHUMP_FEEDBACK_LOG="$feedback" \
        bash "$DELIBERATOR" tick 2>&1 || true
}

assert_contains() {
    local needle="$1" haystack="$2" label="${3:-}"
    if ! printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "FAIL${label:+ [$label]}: expected '$needle' in:"
        printf '%s\n' "$haystack" | head -20
        exit 1
    fi
}

assert_not_contains() {
    local needle="$1" haystack="$2" label="${3:-}"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "FAIL${label:+ [$label]}: did NOT expect '$needle' in:"
        printf '%s\n' "$haystack" | head -20
        exit 1
    fi
}

# ── Scenario A: quorum-meeting proposal, past deadline → consensus_result PASSED ──
echo "[test-deliberator-tick-emits] Scenario A: quorum + past deadline → PASSED"

AMBIENT_A="$TMPDIR_TEST/ambient-a.jsonl"
CORR_A="resilient-061-test-a-$$"

# Proposal filed now with an explicit past deadline.
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"test A","deadline":"%s"}\n' \
    "$NOW_TS" "$CORR_A" "$PAST_DEADLINE" >> "$AMBIENT_A"

# 3 yes-votes (quorum requires >= 3 and yes > no).
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"yes %d","session":"agent-%d"}\n' \
        "$NOW_TS" "$CORR_A" "$i" "$i" >> "$AMBIENT_A"
done

OUT_A="$(_run_tick "$AMBIENT_A")"
echo "[test-deliberator-tick-emits] tick output:"
printf '%s\n' "$OUT_A"

# Must reach completion without error.
assert_contains "resolved=1"           "$OUT_A"  "Scenario A"
assert_contains "verdict=PASSED"       "$OUT_A"  "Scenario A"
assert_contains "emitted kind=consensus_result" "$OUT_A" "Scenario A"

# Ambient file must now contain exactly 1 consensus_result line.
RESULT_COUNT=0
while IFS= read -r _l; do (( RESULT_COUNT++ )) || true; done \
    < <(grep '"kind":"consensus_result"' "$AMBIENT_A" 2>/dev/null || true)
if [[ "$RESULT_COUNT" -ne 1 ]]; then
    echo "FAIL [Scenario A]: expected 1 consensus_result line, got $RESULT_COUNT"
    exit 1
fi

# The emitted event must reference the right corr_id and verdict.
EMITTED=$(grep '"kind":"consensus_result"' "$AMBIENT_A")
assert_contains "\"corr_id\":\"${CORR_A}\""  "$EMITTED"  "Scenario A corr_id"
assert_contains '"verdict":"PASSED"'          "$EMITTED"  "Scenario A verdict"

echo "[test-deliberator-tick-emits] PASS — Scenario A"

# ── Scenario B-1: malformed ts (non-ISO string) → no crash, no emission ──
echo ""
echo "[test-deliberator-tick-emits] Scenario B-1: malformed ts (non-ISO) → skip gracefully"

AMBIENT_B1="$TMPDIR_TEST/ambient-b1.jsonl"
CORR_BAD="resilient-061-bad-ts-$$"

# Proposal with a completely unparseable ts.
printf '{"ts":"NOT-AN-ISO-DATE","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"bad ts"}\n' \
    "$CORR_BAD" >> "$AMBIENT_B1"
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"session":"s%d"}\n' \
        "$NOW_TS" "$CORR_BAD" "$i" >> "$AMBIENT_B1"
done

# This must NOT crash (set -euo pipefail would propagate any arithmetic error).
# _run_tick uses || true so exit code is always 0; crash detection via output.
OUT_B1="$(_run_tick "$AMBIENT_B1")"

echo "[test-deliberator-tick-emits] tick output (B-1): $OUT_B1"
if printf '%s' "$OUT_B1" | grep -qE "bad math expression|syntax error in expression"; then
    echo "FAIL [Scenario B-1]: tick output contains arithmetic crash message"
    exit 1
fi

# No consensus_result for the malformed proposal.
CR_COUNT=0
if grep -q '"kind":"consensus_result"' "$AMBIENT_B1" 2>/dev/null \
   && grep '"kind":"consensus_result"' "$AMBIENT_B1" | grep -q "\"corr_id\":\"${CORR_BAD}\""; then
    CR_COUNT=1
fi
if [[ "$CR_COUNT" -ne 0 ]]; then
    echo "FAIL [Scenario B-1]: emitted consensus_result for malformed-ts proposal (should skip)"
    exit 1
fi

echo "[test-deliberator-tick-emits] PASS — Scenario B-1 (non-ISO ts skipped, no crash)"

# ── Scenario B-2: malformed ts (empty string) → no crash ──
echo ""
echo "[test-deliberator-tick-emits] Scenario B-2: malformed ts (empty) → skip gracefully"

AMBIENT_B2="$TMPDIR_TEST/ambient-b2.jsonl"
CORR_EMPTY="resilient-061-empty-ts-$$"

printf '{"ts":"","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"empty ts"}\n' \
    "$CORR_EMPTY" >> "$AMBIENT_B2"
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"session":"e%d"}\n' \
        "$NOW_TS" "$CORR_EMPTY" "$i" >> "$AMBIENT_B2"
done

# Also add a valid proposal so we can prove the batch continues after the bad one.
CORR_AFTER="resilient-061-after-bad-$$"
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"after bad","deadline":"%s"}\n' \
    "$NOW_TS" "$CORR_AFTER" "$PAST_DEADLINE" >> "$AMBIENT_B2"
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"session":"a%d"}\n' \
        "$NOW_TS" "$CORR_AFTER" "$i" >> "$AMBIENT_B2"
done

OUT_B2="$(_run_tick "$AMBIENT_B2")"

echo "[test-deliberator-tick-emits] tick output (B-2): $OUT_B2"
if printf '%s' "$OUT_B2" | grep -qE "bad math expression|syntax error in expression"; then
    echo "FAIL [Scenario B-2]: tick output contains arithmetic crash message"
    exit 1
fi

# The valid proposal AFTER the bad one must still get resolved.
assert_contains "resolved=1"  "$OUT_B2"  "Scenario B-2 batch continues after bad ts"
CR_AFTER=0
if grep -q '"kind":"consensus_result"' "$AMBIENT_B2" 2>/dev/null \
   && grep '"kind":"consensus_result"' "$AMBIENT_B2" | grep -q "\"corr_id\":\"${CORR_AFTER}\""; then
    CR_AFTER=1
fi
if [[ "$CR_AFTER" -ne 1 ]]; then
    echo "FAIL [Scenario B-2]: expected consensus_result for valid proposal after malformed-ts one, got $CR_AFTER"
    exit 1
fi

# No emission for the empty-ts proposal.
CR_EMPTY=0
if grep -q '"kind":"consensus_result"' "$AMBIENT_B2" 2>/dev/null \
   && grep '"kind":"consensus_result"' "$AMBIENT_B2" | grep -q "\"corr_id\":\"${CORR_EMPTY}\""; then
    CR_EMPTY=1
fi
if [[ "$CR_EMPTY" -ne 0 ]]; then
    echo "FAIL [Scenario B-2]: emitted consensus_result for empty-ts proposal (should skip)"
    exit 1
fi

echo "[test-deliberator-tick-emits] PASS — Scenario B-2 (empty ts skipped, batch continues)"

# ── Scenario C: idempotency — second tick must not double-emit ──
echo ""
echo "[test-deliberator-tick-emits] Scenario C: idempotency — second tick must not double-emit"

AMBIENT_C="$TMPDIR_TEST/ambient-c.jsonl"
CORR_C="resilient-061-idem-$$"

printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"idempotent","deadline":"%s"}\n' \
    "$NOW_TS" "$CORR_C" "$PAST_DEADLINE" >> "$AMBIENT_C"
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"session":"i%d"}\n' \
        "$NOW_TS" "$CORR_C" "$i" >> "$AMBIENT_C"
done

# First tick — should emit.
OUT_C1="$(_run_tick "$AMBIENT_C")"
assert_contains "resolved=1" "$OUT_C1" "Scenario C first tick"

# Second tick — must skip the already-resolved proposal.
OUT_C2="$(_run_tick "$AMBIENT_C")"
assert_contains "already resolved" "$OUT_C2" "Scenario C second tick idempotency"

# Exactly 1 consensus_result in the file.
CR_C=0
while IFS= read -r _l; do (( CR_C++ )) || true; done \
    < <(grep '"kind":"consensus_result"' "$AMBIENT_C" 2>/dev/null || true)
if [[ "$CR_C" -ne 1 ]]; then
    echo "FAIL [Scenario C]: expected exactly 1 consensus_result after two ticks, got $CR_C"
    exit 1
fi

echo "[test-deliberator-tick-emits] PASS — Scenario C (idempotency confirmed)"

# ── Scenario D: RESILIENT-062 — proposal+votes in the DURABLE feedback.jsonl (NOT
#    ambient) are still seen + tallied (consensus no longer ages out of pruned ambient) ──
echo ""
echo "[test-deliberator-tick-emits] Scenario D: proposal only in feedback.jsonl → seen + resolved"
AMBIENT_D="$TMPDIR_TEST/ambient-d.jsonl"
FEEDBACK_D="$TMPDIR_TEST/feedback-d.jsonl"
CORR_D="resilient-062-feedback-$$"
# ambient deliberately lacks the proposal (simulates it reaped from the audit stream).
printf '{"ts":"%s","event":"ALERT","kind":"unrelated_noise"}\n' "$NOW_TS" >> "$AMBIENT_D"
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"feedback-only","deadline":"%s"}\n' \
    "$NOW_TS" "$CORR_D" "$PAST_DEADLINE" >> "$FEEDBACK_D"
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"session":"d%d"}\n' \
        "$NOW_TS" "$CORR_D" "$i" >> "$FEEDBACK_D"
done
if grep -q "$CORR_D" "$AMBIENT_D" 2>/dev/null; then
    echo "FAIL [Scenario D]: corr_id leaked into the ambient fixture — test setup bug"; exit 1
fi
OUT_D="$(_run_tick "$AMBIENT_D" "$FEEDBACK_D")"
echo "[test-deliberator-tick-emits] tick output (D): $OUT_D"
assert_contains "verdict=PASSED" "$OUT_D" "Scenario D feedback.jsonl read"
CR_D=0
if grep -q '"kind":"consensus_result"' "$AMBIENT_D" 2>/dev/null \
   && grep '"kind":"consensus_result"' "$AMBIENT_D" | grep -q "\"corr_id\":\"${CORR_D}\""; then
    CR_D=1
fi
if [[ "$CR_D" -ne 1 ]]; then
    echo "FAIL [Scenario D]: proposal living only in feedback.jsonl was NOT tallied (RESILIENT-062 regression)"; exit 1
fi
echo "[test-deliberator-tick-emits] PASS — Scenario D (durable feedback.jsonl scanned, not ambient-dependent)"

echo ""
echo "[test-deliberator-tick-emits] ALL PASS — RESILIENT-061 AC #4 + RESILIENT-062 verified"
