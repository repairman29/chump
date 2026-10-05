#!/usr/bin/env bash
# scripts/ci/test-sandbox-discipline.sh — INFRA-2088
#
# CI lint: a NEW test script (added in the diff, under scripts/ci/*.sh) must
# not hand-roll "mktemp a dir, then manually export CHUMP_HOME / CHUMP_REPO /
# CHUMP_REPO_ROOT / CHUMP_STATE_DB / CHUMP_LOCK_DIR" isolation. New scripts
# that need a sandboxed `chump` invocation must source
# scripts/coord/lib/test-sandbox.sh and call chump_test_sandbox_setup /
# chump_test_sandbox_cleanup instead — that's the single source of truth for
# the isolation-var list (INFRA-2080 class: per-test env-var drift).
#
# Existing scripts are grandfathered — this gate only fires on NEW files, so
# pre-existing hand-rolled sandboxes don't need a forced migration to pass CI.
#
# Usage:
#   bash scripts/ci/test-sandbox-discipline.sh        # full mode
#   BASE_REF=some-branch bash scripts/ci/...          # custom base ref

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

base="${BASE_REF:-origin/main}"
git fetch origin main --quiet 2>/dev/null || true

# Files added (status A) by this diff, restricted to scripts/ci/*.sh.
new_files="$(git diff --name-status "${base}...HEAD" 2>/dev/null | awk '$1=="A"{print $2}')"
if [ -z "$new_files" ]; then
    new_files="$(git diff --name-status "${base}..HEAD" 2>/dev/null | awk '$1=="A"{print $2}')"
fi

VIOLATIONS=0

while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
        scripts/ci/*.sh) ;;
        *) continue ;;
    esac
    [ -f "$f" ] || continue
    # The primitive's own lib/smoke-test files are exempt by construction.
    case "$f" in
        scripts/coord/lib/test-sandbox.sh|scripts/ci/test-chump-test-sandbox.sh|scripts/ci/test-sandbox-discipline.sh)
            continue
            ;;
    esac

    if grep -q 'test-sandbox\.sh' "$f"; then
        # Already sources the canonical primitive — fine.
        continue
    fi

    if grep -qE 'mktemp' "$f" && \
       grep -qE 'CHUMP_(HOME|REPO|REPO_ROOT|STATE_DB|LOCK_DIR)=' "$f"; then
        echo "VIOLATION: $f mktemp's a sandbox dir and manually sets CHUMP isolation env vars"
        echo "  -> source scripts/coord/lib/test-sandbox.sh and use chump_test_sandbox_setup/cleanup instead"
        VIOLATIONS=$((VIOLATIONS+1))
    fi
done <<< "$new_files"

if [ "$VIOLATIONS" -gt 0 ]; then
    echo ""
    echo "=== $VIOLATIONS new test script(s) hand-roll sandbox isolation (INFRA-2088) ==="
    exit 1
fi

echo "=== sandbox-discipline: no new hand-rolled sandboxes ==="
exit 0
