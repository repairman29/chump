#!/usr/bin/env bash
# test-cascade-status-pr.sh — INFRA-5430 (INFRA-1861 slice)
#
# Smoke test for scripts/ci/post-cascade-status.sh's description-building
# logic and no-op behavior. Uses --dry-run so no `gh api` call / network /
# GitHub auth is required.
#
# Run:
#   bash scripts/ci/test-cascade-status-pr.sh
#
# Exit 0 = all assertions pass; exit 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/post-cascade-status.sh"

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$SCRIPT" ]] || fail "script missing: $SCRIPT"
bash -n "$SCRIPT" || fail "script fails syntax check"
pass "script exists and parses cleanly"

# ── 1. No cancelled jobs → no-op, exit 0, no description line ────────────────
OUT1=$(bash "$SCRIPT" --dry-run 2>&1)
RC1=$?
[[ "$RC1" -eq 0 ]] || fail "no-cancels case: expected exit 0, got $RC1"
echo "$OUT1" | grep -q "nothing to report\|skipping" || fail "no-cancels case: expected no-op message (got: $OUT1)"
pass "no cancelled jobs → no-op"

# ── 2. cascade_cancels only, with a real_failures cause ───────────────────────
OUT2=$(bash "$SCRIPT" --dry-run --cascade-cancels "clippy,cargo-test" --real-failures "fast-checks")
echo "$OUT2" | grep -q "Cancelled (caused by fast-checks): clippy, cargo-test" \
    || fail "cascade-cancels case: unexpected description (got: $OUT2)"
pass "cascade_cancels description includes job names + cause"

# ── 3. supersedure_cancels only ───────────────────────────────────────────────
OUT3=$(bash "$SCRIPT" --dry-run --supersedure-cancels "fast-checks,clippy,cargo-test,pr-hygiene")
echo "$OUT3" | grep -q "Cancelled (superseded by a newer run): fast-checks, clippy, cargo-test, pr-hygiene" \
    || fail "supersedure-cancels case: unexpected description (got: $OUT3)"
pass "supersedure_cancels description includes job names + cause"

# ── 4. both cascade + supersedure cancels present ─────────────────────────────
OUT4=$(bash "$SCRIPT" --dry-run --cascade-cancels "clippy" --real-failures "fast-checks" --supersedure-cancels "pr-hygiene")
echo "$OUT4" | grep -q "Cancelled (caused by fast-checks): clippy; Cancelled (superseded by a newer run): pr-hygiene" \
    || fail "combined case: unexpected description (got: $OUT4)"
pass "combined cascade + supersedure description is joined and readable"

# ── 5. missing --sha on a live (non-dry-run) invocation errors out ───────────
OUT5=$(bash "$SCRIPT" --cascade-cancels "clippy" --real-failures "fast-checks" 2>&1)
RC5=$?
[[ "$RC5" -ne 0 ]] || fail "live invocation without --sha should fail (got exit 0)"
echo "$OUT5" | grep -q "\-\-sha required" || fail "expected --sha-required error (got: $OUT5)"
pass "live invocation without --sha fails loudly"

# ── 6. long description is truncated to GitHub's 140-char status cap ─────────
LONG_LIST="job-aaaaaaaaaa,job-bbbbbbbbbb,job-cccccccccc,job-dddddddddd,job-eeeeeeeeee,job-ffffffffff,job-gggggggggg,job-hhhhhhhhhh"
OUT6=$(bash "$SCRIPT" --dry-run --cascade-cancels "$LONG_LIST" --real-failures "fast-checks")
DESC6=$(echo "$OUT6" | sed -n 's/^\[post-cascade-status\] description: //p')
LEN6=${#DESC6}
[[ "$LEN6" -le 140 ]] || fail "description exceeds 140 chars (got $LEN6): $DESC6"
pass "long description truncated to <=140 chars (got $LEN6)"

echo
echo "All INFRA-5430 cascade-status PR-description tests passed."
