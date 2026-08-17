#!/usr/bin/env bash
# scripts/ci/test-audit-workflow-not-cancellable.sh — INFRA-2452 / INFRA-2516
#
# Regression guard: asserts that the `audit` and `audit-required` jobs live in
# their own dedicated workflow file (audit.yml), isolated from ci.yml's
# workflow-level concurrency block. This prevents the recurring trunk-red
# deadlock where ci.yml's workflow-level cancel-in-progress: true cancels the
# required `audit` check as collateral damage from an unrelated job's fixup
# push, causing audit → CANCELLED, audit-required → FAILURE, and every PR
# blocked — including the PR that fixes it. (3h fleet-wide deadlock on 2026-06-02)
#
# INFRA-2516 update: audit.yml's OWN concurrency now uses cancel-in-progress:
# true with a per-PR group (not per-SHA/per-run-id) so a newer push to the
# SAME PR cancels its own superseded audit run instead of piling up stale
# runs against a fixed runner pool (13 in-flight runs vs 4 runners wedged the
# queue ~30min on 2026-06-03). This is scoped to audit.yml alone and keyed
# per-PR — it does not reintroduce the INFRA-2452 cross-workflow collateral
# cancellation, which checks 3/4 below continue to guard against.
#
# What this asserts (inverse of broken state — if this test fails, the regression is back):
#   1. audit.yml exists (jobs moved out of ci.yml)
#   2. audit.yml's top-level concurrency is per-PR (not per-SHA/run-id) with cancel-in-progress: true
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

# 2. audit.yml must have workflow-level cancel-in-progress: true, keyed per-PR
# (not per-SHA/run-id — that variant never collides, so stale runs pile up
# regardless of cancel-in-progress; see INFRA-2516).
# The workflow-level concurrency block is at the top level (not indented under jobs:)
if [[ -f "$AUDIT_YML" ]]; then
    concurrency_block="$(awk '/^concurrency:/{flag=1; next} flag && /^[a-zA-Z]/{flag=0} flag' "$AUDIT_YML")"
    cancel_val="$(printf '%s\n' "$concurrency_block" | grep 'cancel-in-progress:' | awk '{print $2}' | head -1)"
    group_line="$(printf '%s\n' "$concurrency_block" | grep 'group:' | head -1)"

    if [[ "$cancel_val" == "true" ]]; then
        ok "audit.yml workflow-level cancel-in-progress: true"
    else
        fail "audit.yml workflow-level cancel-in-progress is '$cancel_val' (expected 'true') — stale-run pileup regression (INFRA-2516)"
    fi

    if [[ "$group_line" == *github.sha* || "$group_line" == *github.run_id* ]]; then
        fail "audit.yml concurrency group is keyed per-SHA/run-id — never collides, cancel-in-progress is a no-op (INFRA-2516 regression): $group_line"
    elif [[ "$group_line" == *pull_request.number* || "$group_line" == *github.ref* ]]; then
        ok "audit.yml concurrency group is keyed per-PR/ref (not per-SHA/run-id)"
    else
        fail "audit.yml concurrency group does not look per-PR/ref — verify manually: $group_line"
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
