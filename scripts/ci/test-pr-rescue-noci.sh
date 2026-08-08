#!/usr/bin/env bash
# RESILIENT-248: prove the zero-CI-runs detector in pr-rescue.sh.
#
# Why a fixture and not an integration test: the bug is a GitHub-side webhook
# failure that cannot be reproduced on demand. PR #3489 sat 2h35m with zero
# workflow runs and merged 9 minutes after a close/reopen — we cannot make that
# happen again to test it. So we test the DECISION, exhaustively, at the one
# place it is made.
#
# The failure this guards against is EFFECTIVE-407's class: a detector that is
# blind to its own target case still reports a clean bill of health. Proving it
# STAYS QUIET matters as much as proving it fires — this code path closes and
# reopens real PRs on a 2h cron.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../coord/pr-rescue.sh
PR_RESCUE_LIB_ONLY=1 source "${REPO_ROOT}/scripts/coord/pr-rescue.sh"

if ! declare -F pr_rescue_should_refire >/dev/null; then
    echo "FAIL: pr_rescue_should_refire not defined — is the LIB_ONLY guard still in pr-rescue.sh?" >&2
    exit 1
fi

PASS=0
FAIL=0

# expect_fire <label> <checks> <age_min> <threshold>
expect_fire() {
    local label="$1"; shift
    if pr_rescue_should_refire "$@"; then
        PASS=$((PASS + 1)); echo "  ok   FIRES  — ${label}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL want fire, stayed quiet — ${label}" >&2
    fi
}

expect_quiet() {
    local label="$1"; shift
    if pr_rescue_should_refire "$@"; then
        FAIL=$((FAIL + 1)); echo "  FAIL want quiet, FIRED — ${label}" >&2
    else
        PASS=$((PASS + 1)); echo "  ok   quiet  — ${label}"
    fi
}

echo "=== RESILIENT-248 zero-CI-runs detector ==="

# The incident itself. PR #3489: zero runs, 155 minutes old, default 25m gate.
expect_fire  "the DOC-085 incident — 0 checks, 155m old"        0 155 25
expect_fire  "exactly at threshold"                             0  25 25
expect_fire  "long-dead PR, no checks"                          0 999 25

# A single check means the trigger DID fire and CI is merely slow or queued.
# Re-firing that cancels real work — the most damaging false positive here.
expect_quiet "1 queued check — trigger fired, CI just slow"     1 155 25
expect_quiet "full check suite present"                        19 155 25
expect_quiet "zero checks but too young to judge"               0  24 25
expect_quiet "brand new PR"                                     0   0 25

# A failed API call must never be read as "zero checks". Returning ERR or an
# empty string from the check-runs query is the realistic failure, and treating
# it as zero would re-fire the entire open queue during a GitHub outage.
expect_quiet "API error string, not a count"                  ERR 155 25
expect_quiet "empty count (curl failed)"                       "" 155 25
expect_quiet "null from jq"                                  null 155 25
expect_quiet "non-numeric age"                                  0  "" 25
expect_quiet "garbage threshold"                                0 155 ""

echo "--- ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]] || exit 1
echo "PASS: detector fires on the incident signature and stays quiet on all ${PASS} guard cases."
