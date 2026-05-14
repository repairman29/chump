#!/usr/bin/env bash
# INFRA-422 — verify bot-merge.sh runs chump-binary-unwedge.sh as preflight before
# any chump invocation. The wiring landed organically (bot-merge.sh:563-568)
# but had no regression guard; this test pins the contract so a later
# refactor doesn't silently regress.
#
# Strategy: static check on bot-merge.sh — the chump-doctor invocation
# must (a) be present, (b) be conditional on CHUMP_DOCTOR_SKIP, (c) sit
# BEFORE the first chump-binary call. We can't easily simulate a wedged
# syspolicyd inode in CI, so the e2e heal path stays manual; the static
# check catches the regression we actually care about.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
DOC="$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh"

[[ -x "$BM" ]]  || { fail "bot-merge.sh missing or not executable"; exit 1; }
[[ -x "$DOC" ]] || { fail "chump-binary-unwedge.sh missing or not executable"; exit 1; }
pass "bot-merge.sh and chump-binary-unwedge.sh both exist + executable"

# 1. bot-merge.sh references chump-binary-unwedge.sh.
grep -q 'chump-binary-unwedge.sh' "$BM" \
    && pass "bot-merge.sh references chump-binary-unwedge.sh" \
    || fail "bot-merge.sh has no chump-binary-unwedge.sh invocation"

# 2. Invocation is gated by CHUMP_DOCTOR_SKIP env var (so the chump-doctor
#    PR itself or cron-side jobs can bypass).
grep -q 'CHUMP_DOCTOR_SKIP' "$BM" \
    && pass "bot-merge.sh respects CHUMP_DOCTOR_SKIP bypass" \
    || fail "bot-merge.sh missing CHUMP_DOCTOR_SKIP bypass"

# 3. Doctor invocation precedes the first chump-binary call. We compare
#    line numbers — the doctor block must come before any `chump gap`,
#    `chump --briefing`, etc. (the explicit binary calls; substring
#    'chump' matches a lot of unrelated tokens like 'chump-locks' so we
#    grep for the binary-style invocation).
DOCTOR_LINE=$(grep -n 'scripts/dev/chump-binary-unwedge.sh' "$BM" | head -1 | cut -d: -f1 || echo 0)
FIRST_CHUMP_CALL=$(grep -nE '(^|[^a-z-])chump (gap|--briefing|--release|--execute-gap)' "$BM" \
    | head -1 | cut -d: -f1 || echo 99999)
if [[ "$DOCTOR_LINE" -gt 0 && "$DOCTOR_LINE" -lt "$FIRST_CHUMP_CALL" ]]; then
    pass "chump-doctor preflight (line $DOCTOR_LINE) runs before first chump call (line $FIRST_CHUMP_CALL)"
else
    fail "chump-doctor must run before first chump invocation (doctor=$DOCTOR_LINE first_chump=$FIRST_CHUMP_CALL)"
fi

# 4. chump-binary-unwedge.sh itself probes-then-heals (the contract bot-merge depends on).
grep -q 'gtimeout.*--version' "$DOC" \
    && pass "chump-binary-unwedge.sh probes via --version + gtimeout" \
    || fail "chump-binary-unwedge.sh missing the --version probe"

grep -q 'wedged-inode' "$DOC" \
    && pass "chump-binary-unwedge.sh has the inode-replacement heal path" \
    || fail "chump-binary-unwedge.sh missing the heal path"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
