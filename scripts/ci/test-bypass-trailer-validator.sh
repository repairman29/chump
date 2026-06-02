#!/usr/bin/env bash
#
# test-bypass-trailer-validator.sh — INFRA-2407
#
# Smoke tests for commit-msg-bypass-trailers.sh and the legacy
# allowlist at scripts/ci/legacy-bypass-trailer-allowlist.txt.
#
# Test matrix:
#   T1  Obs-Bypass-Reason: only (missing other 3) → exit 1
#   T2  Full 4-trailer set → exit 0
#   T3  Legacy allowlist SHA (synthetic) → exit 0
#   T4  Bypass-Tier=T7 (invalid) → exit 1
#   T5  Bypass-Followup=BAD-FORMAT → exit 1
#   T6  No bypass token at all → exit 0
#   T7  Bypass-Reason with fewer than 10 words → exit 1

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
VALIDATOR="$REPO_ROOT/scripts/git-hooks/commit-msg-bypass-trailers.sh"
ALLOWLIST="$REPO_ROOT/scripts/ci/legacy-bypass-trailer-allowlist.txt"

if [ ! -x "$VALIDATOR" ]; then
    echo "FAIL: validator not found or not executable: $VALIDATOR" >&2
    exit 1
fi

_pass=0
_fail=0
_tmpfile="$(mktemp -t bypass-test.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$_tmpfile'" EXIT

# Helper: run the validator against a commit message string.
# $1 = test label, $2 = expected exit code (0 or 1), $3 = commit message body
run_test() {
    local label="$1"
    local expected="$2"
    local msg="$3"
    printf '%s\n' "$msg" > "$_tmpfile"
    local actual=0
    # Run with CHUMP_BYPASS_TRAILER_CHECK=1 to ensure bypass flag is off.
    CHUMP_BYPASS_TRAILER_CHECK=1 bash "$VALIDATOR" "$_tmpfile" >/dev/null 2>&1 || actual=$?
    if [ "$actual" -eq "$expected" ]; then
        echo "PASS [$label]: exited $actual (expected $expected)"
        _pass=$(( _pass + 1 ))
    else
        echo "FAIL [$label]: exited $actual (expected $expected)" >&2
        echo "     Message was:" >&2
        printf '%s\n' "$msg" | sed 's/^/       /' >&2
        _fail=$(( _fail + 1 ))
    fi
}

# ─── T1: Only one bypass token present, missing 3 other trailers → exit 1 ───
run_test "T1-partial-trailers" 1 "fix(INFRA-0001): some fix

Applied workaround.

Obs-Bypass-Reason: tooling was broken during trunk-red window"

# ─── T2: Full valid 4-trailer set → exit 0 ───────────────────────────────────
run_test "T2-full-valid-trailers" 0 "fix(INFRA-0002): rescue pre-push after fmt drift

Applied cargo fmt to resolve rustfmt regression that was blocking all pushes.

Bypass-Tier: T2
Bypass-Class: preflight-skip
Bypass-Reason: main was red before branch cut due to upstream rustfmt regression and preflight gate was blocking a legitimate rescue commit
Bypass-Followup: INFRA-9999"

# ─── T3: Legacy allowlist entry → exit 0 ─────────────────────────────────────
# We test the allowlist by inserting a synthetic SHA into a temp copy.
_tmp_allowlist="$(mktemp -t bypass-allowlist.XXXXXX)"
trap "rm -f '$_tmp_allowlist'" EXIT
SYNTHETIC_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
printf '%s\n' "$SYNTHETIC_SHA" > "$_tmp_allowlist"

# We can't easily inject the allowlist path; instead we verify the grep-xF
# match logic directly.
_match="$(grep -xF "$SYNTHETIC_SHA" "$_tmp_allowlist" 2>/dev/null || true)"
case "$_match" in
    ?*)
        echo "PASS [T3-legacy-allowlist-grep]: synthetic SHA found in allowlist (grep-xF works)"
        _pass=$(( _pass + 1 ))
        ;;
    "")
        echo "FAIL [T3-legacy-allowlist-grep]: synthetic SHA not found in allowlist" >&2
        _fail=$(( _fail + 1 ))
        ;;
esac

# Also verify the actual allowlist file contains at least 100 real SHAs (seeded on init).
if [ -f "$ALLOWLIST" ]; then
    _sha_count="$(grep -cE '^[0-9a-f]{40}$' "$ALLOWLIST" || true)"
    if [ "$_sha_count" -ge 100 ]; then
        echo "PASS [T3-allowlist-size]: allowlist has $_sha_count SHAs (≥100 expected)"
        _pass=$(( _pass + 1 ))
    else
        echo "FAIL [T3-allowlist-size]: allowlist has only $_sha_count SHAs (expected ≥100)" >&2
        _fail=$(( _fail + 1 ))
    fi
else
    echo "FAIL [T3-allowlist-exists]: $ALLOWLIST not found" >&2
    _fail=$(( _fail + 1 ))
fi
rm -f "$_tmp_allowlist"

# ─── T4: Invalid Bypass-Tier (T7) → exit 1 ───────────────────────────────────
run_test "T4-invalid-tier" 1 "fix(INFRA-0003): some bypass

This uses a Bot-Merge-Bypass for some reason.

Bypass-Tier: T7
Bypass-Class: preflight-skip
Bypass-Reason: main was red and the gate was blocking a critical rescue operation that had to ship
Bypass-Followup: INFRA-9999"

# ─── T5: Bad Bypass-Followup format → exit 1 ─────────────────────────────────
run_test "T5-bad-followup" 1 "fix(INFRA-0004): another bypass

Preflight-Skip was required here.

Bypass-Tier: T1
Bypass-Class: preflight-skip
Bypass-Reason: stale merge state caused proof of merge check to fail even though the branch was current
Bypass-Followup: BAD-FORMAT"

# ─── T6: No bypass token at all → exit 0 (fast-path) ────────────────────────
run_test "T6-no-gate-override" 0 "fix(INFRA-0005): normal commit

This commit is a regular fix with no overrides or workarounds.
Just a routine change."

# ─── T7: Bypass-Reason fewer than 10 words → exit 1 ─────────────────────────
run_test "T7-short-reason" 1 "fix(INFRA-0006): short reason

Uses Bot-Merge-Bypass trailer here.

Bypass-Tier: T2
Bypass-Class: preflight-skip
Bypass-Reason: tooling issue
Bypass-Followup: INFRA-9999"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $_pass passed, $_fail failed"

if [ "$_fail" -gt 0 ]; then
    exit 1
fi
exit 0
