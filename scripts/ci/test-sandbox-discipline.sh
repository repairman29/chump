#!/usr/bin/env bash
# scripts/ci/test-sandbox-discipline.sh — INFRA-2088
#
# Lint-style gate: no NEW scripts/ci/*.sh test script (added in the current
# diff vs. origin/main) may hand-roll a "mkdir a temp dir, set CHUMP_HOME/
# CHUMP_REPO/CHUMP_REPO_ROOT/CHUMP_STATE_DB/CHUMP_LOCK_DIR by hand" sandbox
# setup — it must source scripts/coord/lib/test-sandbox.sh and use
# chump_test_sandbox_setup / chump_test_sandbox_cleanup instead. This is
# the forward-looking half of the INFRA-2080 fix: the primitive
# (scripts/coord/lib/test-sandbox.sh) is the cure for existing drift, this
# gate is the guard against new drift.
#
# Existing (pre-INFRA-2088) scripts are NOT retroactively failed here —
# migrating the full existing fleet of sandbox-rolling test scripts is
# tracked separately. This gate only fires on scripts that are NEW in the
# diff.
#
# Run from repo root: bash scripts/ci/test-sandbox-discipline.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BASE_REF="${CHUMP_SANDBOX_DISCIPLINE_BASE:-origin/main}"
if ! git rev-parse --verify -q "$BASE_REF" >/dev/null; then
    BASE_REF="main"
fi
if ! git rev-parse --verify -q "$BASE_REF" >/dev/null; then
    echo "SKIP: no base ref ($BASE_REF) to diff against — nothing to check" >&2
    exit 0
fi

# New scripts/ci/*.sh files added since $BASE_REF (Added status only — we
# don't want to fail a script for pre-existing sandbox code it merely
# touched incidentally).
mapfile -t NEW_SCRIPTS < <(git diff --name-only --diff-filter=A "$BASE_REF"...HEAD -- 'scripts/ci/*.sh' 2>/dev/null)

if [[ ${#NEW_SCRIPTS[@]} -eq 0 ]]; then
    echo "no new scripts/ci/*.sh files vs $BASE_REF — nothing to check"
    exit 0
fi

FAIL=0
for f in "${NEW_SCRIPTS[@]}"; do
    [[ -f "$f" ]] || continue
    # Heuristic for "hand-rolled sandbox": creates a temp dir AND exports one
    # of the isolation env vars manually, without sourcing the primitive.
    manual_tmp=$(grep -qE 'mktemp[[:space:]]+-d' "$f" && echo 1 || echo 0)
    manual_env=$(grep -qE 'CHUMP_(HOME|REPO|REPO_ROOT|STATE_DB|LOCK_DIR)=' "$f" && echo 1 || echo 0)
    uses_primitive=$(grep -qE 'test-sandbox\.sh|chump_test_sandbox_(setup|cleanup)' "$f" && echo 1 || echo 0)

    if [[ "$manual_tmp" == "1" && "$manual_env" == "1" && "$uses_primitive" == "0" ]]; then
        echo "[FAIL] $f: hand-rolls a sandbox (mktemp -d + CHUMP_* env vars) without sourcing scripts/coord/lib/test-sandbox.sh" >&2
        echo "       Use chump_test_sandbox_setup / chump_test_sandbox_cleanup instead (see scripts/ci/test-gap-reserve-padding.sh for an example)." >&2
        FAIL=1
    fi
done

if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: all new scripts/ci/*.sh test scripts use the canonical sandbox primitive (or don't need one)"
fi
exit "$FAIL"
