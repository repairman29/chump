#!/usr/bin/env bash
# scripts/ci/test-workflow-concurrency-triggers.sh — ZERO-WASTE-135
#
# Asserts every GitHub Actions workflow file under .github/workflows/ that is
# triggered by workflow_run or schedule declares a concurrency block with a
# group field. This prevents queue starvation from duplicate runs of the same
# workflow.
#
# Allowlist: workflows that legitimately have no concurrency group (e.g.,
# workflows that are idempotent and should run concurrently) can be added
# to ALLOWED_NO_CONCURRENCY below with a reason.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WF_DIR="$REPO_ROOT/.github/workflows"

# Workflows that are allowed to NOT have a concurrency group.
# Only add with strong justification (e.g., entirely read-only, or deliberately concurrent).
declare -A ALLOWED_NO_CONCURRENCY=(
  # Add entries as: [workflow_name]="reason"
)

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== ZERO-WASTE-135: workflow_run + schedule concurrency audit ==="
echo

for wf in "$WF_DIR"/*.yml; do
    name="$(basename "$wf")"

    # Check if this workflow is triggered by workflow_run or schedule.
    has_workflow_run=0
    has_schedule=0

    if grep -qE "^\s*workflow_run:" "$wf"; then
        has_workflow_run=1
    fi
    if grep -qE "^\s*schedule:" "$wf"; then
        has_schedule=1
    fi

    # Skip if neither trigger is present.
    if [ "$has_workflow_run" -eq 0 ] && [ "$has_schedule" -eq 0 ]; then
        continue
    fi

    # Check if in allowlist.
    if [ -v "ALLOWED_NO_CONCURRENCY[$name]" ]; then
        ok "$name allowed (${ALLOWED_NO_CONCURRENCY[$name]})"
        continue
    fi

    # Require concurrency block with group field.
    if ! grep -qE "^concurrency:" "$wf"; then
        fail "$name (workflow_run/schedule trigger) missing 'concurrency:' block"
        continue
    fi

    if ! awk '/^concurrency:/{flag=1; next} flag && /^[a-zA-Z]/{flag=0} flag' "$wf" | grep -qE "^\s*group:"; then
        fail "$name (workflow_run/schedule trigger) concurrency block missing 'group:' field"
        continue
    fi

    ok "$name (workflow_run/schedule trigger) has concurrency group"
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
