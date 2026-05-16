#!/usr/bin/env bash
# scripts/ci/test-workflow-cancel-in-progress.sh — INFRA-1378
#
# Asserts every GitHub Actions workflow file under .github/workflows/ declares
# a top-level `concurrency:` block with both `group:` and `cancel-in-progress:`
# fields. Without these the convoy cascade (~800 CI-min/hr wasted on the
# 2026-05-15 audit) silently re-runs.
#
# Policy:
# - Every workflow MUST declare a concurrency block.
# - cancel-in-progress: true is recommended for PR-driven workflows; false is
#   acceptable for nightly/main-push/release workflows where preempting would
#   leave artifacts in an inconsistent state. The script enforces the field
#   exists; the value is a workflow-author decision.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WF_DIR="$REPO_ROOT/.github/workflows"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1378 workflow concurrency audit ==="
echo

for wf in "$WF_DIR"/*.yml; do
    name="$(basename "$wf")"
    if ! grep -qE "^concurrency:" "$wf"; then
        fail "$name missing top-level 'concurrency:' block"
        continue
    fi
    # Block must include `group:` field.
    if ! awk '/^concurrency:/{flag=1; next} flag && /^[a-zA-Z]/{flag=0} flag' "$wf" | grep -qE "^\s*group:"; then
        fail "$name concurrency block missing 'group:' field"
        continue
    fi
    # Block must include `cancel-in-progress:` field (value can be true or false).
    if ! awk '/^concurrency:/{flag=1; next} flag && /^[a-zA-Z]/{flag=0} flag' "$wf" | grep -qE "^\s*cancel-in-progress:"; then
        fail "$name concurrency block missing 'cancel-in-progress:' field"
        continue
    fi
    ok "$name has full concurrency block"
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
