#!/usr/bin/env bash
# INFRA-3579 (INFRA-1655 slice): regression guard for the INFRA-1852 fix.
#
# INFRA-1852 found that ci.yml's `concurrency:` group for pull_request events
# was keyed on PR number, so consecutive pushes to the same PR cancelled each
# other's in-flight `audit` job — the aggregator then flipped to FAILURE
# because cancelled != success. Fix: key non-push events on `github.sha`
# instead, so each commit gets its own concurrency group. This test guards
# against the group key silently reverting to a PR-number/ref key.
set -euo pipefail

CI_YML=".github/workflows/ci.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$CI_YML" ] || fail "$CI_YML not found"

group_line=$(grep -E '^\s*group:\s*ci-' "$CI_YML" | head -1)
[ -n "$group_line" ] || fail "$CI_YML missing top-level concurrency 'group:' line"

printf '%s\n' "$group_line" | grep -q 'github.sha' \
  || fail "$CI_YML concurrency group is not keyed on github.sha (INFRA-1852 regression) — got: $group_line"

printf '%s\n' "$group_line" | grep -Eq 'pull_request\.number' \
  && fail "$CI_YML concurrency group is keyed on pull_request.number again (INFRA-1852 regression) — got: $group_line"

cancel_line=$(grep -E '^\s*cancel-in-progress:' "$CI_YML" | head -1)
[ -n "$cancel_line" ] || fail "$CI_YML missing top-level concurrency 'cancel-in-progress:' line"

printf '%s\n' "$cancel_line" | grep -q 'true' \
  || fail "$CI_YML cancel-in-progress is not a bare 'true' (INFRA-1001 regression risk) — got: $cancel_line"

echo "OK: ci.yml concurrency group is keyed on github.sha, not pull_request.number (INFRA-1852 fix intact)"
