#!/usr/bin/env bash
# scripts/ci/test-audit-workflow-not-cancellable.sh — INFRA-2452
#
# Regression guard: asserts that the `audit` and `audit-required` jobs live in
# their own dedicated workflow file (audit.yml) with cancel-in-progress: FALSE
# at the workflow level. This prevents the recurring trunk-red deadlock where
# ci.yml's workflow-level cancel-in-progress: true cancels the required `audit`
# check, causing audit → CANCELLED, audit-required → FAILURE, and every PR
# blocked — including the PR that fixes it. (3h fleet-wide deadlock on 2026-06-02)
#
# What this asserts (inverse of broken state — if this test fails, the regression is back):
#   1. audit.yml exists (jobs moved out of ci.yml)
#   2. audit.yml's top-level concurrency has cancel-in-progress: false
#   3. ci.yml does NOT contain a top-level `audit:` job definition
#   4. ci.yml does NOT contain a top-level `audit-required:` job definition

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
AUDIT_YML="$REPO_ROOT/.github/workflows/audit.yml"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2452: audit workflow isolation ==="
echo

# 1. audit.yml must exist
if [[ -f "$AUDIT_YML" ]]; then
    ok "audit.yml exists"
else
    fail "audit.yml MISSING — audit job not extracted from ci.yml (INFRA-2452 regression)"
fi

# 2. audit.yml must have workflow-level cancel-in-progress: false
# The workflow-level concurrency block is at the top level (not indented under jobs:)
if [[ -f "$AUDIT_YML" ]]; then
    cancel_val="$(awk '/^concurrency:/{flag=1; next} flag && /^[a-zA-Z]/{flag=0} flag' "$AUDIT_YML" \
        | grep 'cancel-in-progress:' \
        | awk '{print $2}' | head -1)"
    if [[ "$cancel_val" == "false" ]]; then
        ok "audit.yml workflow-level cancel-in-progress: false"
    else
        fail "audit.yml workflow-level cancel-in-progress is '$cancel_val' (expected 'false') — deadlock regression (INFRA-2452)"
    fi
fi

# 3. ci.yml must NOT contain a job named `audit:` at the jobs level
# We look for the pattern "^  audit:" (2-space indent = jobs-level key in ci.yml)
if [[ -f "$CI_YML" ]]; then
    if grep -qE "^  audit:" "$CI_YML"; then
        fail "ci.yml still contains '  audit:' job — audit job not removed from ci.yml (INFRA-2452 regression)"
    else
        ok "ci.yml does not contain '  audit:' job"
    fi
fi

# 4. ci.yml must NOT contain a job named `audit-required:` at the jobs level
if [[ -f "$CI_YML" ]]; then
    if grep -qE "^  audit-required:" "$CI_YML"; then
        fail "ci.yml still contains '  audit-required:' job — audit-required job not removed from ci.yml (INFRA-2452 regression)"
    else
        ok "ci.yml does not contain '  audit-required:' job"
    fi
fi

# 5. audit.yml must contain a job named `audit` (name continuity — branch protection)
if [[ -f "$AUDIT_YML" ]]; then
    if grep -qE "^  audit:" "$AUDIT_YML"; then
        ok "audit.yml contains '  audit:' job (name continuity preserved for branch protection)"
    else
        fail "audit.yml does NOT contain '  audit:' job — check name changed, branch protection will break"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
