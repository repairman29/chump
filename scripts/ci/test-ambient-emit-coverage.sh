#!/usr/bin/env bash
# test-ambient-emit-coverage.sh — INFRA-1241
# CI lint: no raw '>> ambient.jsonl' or '>> $.*ambient' in scripts/coord/
#
# After INFRA-1241 every ambient write in scripts/coord/ must go through
# _ambient_write (scripts/coord/lib/ambient-write.sh). Any direct append
# is a regression that silently drops events on disk-full / perm errors.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0

# Find raw ambient appends that bypass the helper.
# Exclude the helper itself and test-fixture files.
raw=$(grep -rn '>> .*ambient\.jsonl\|>> \$[_A-Za-z]*ambient\b' \
    "$REPO_ROOT/scripts/coord/" \
    --include='*.sh' \
    --exclude='ambient-write.sh' \
    2>/dev/null || true)

if [[ -n "$raw" ]]; then
    echo "FAIL: raw ambient appends found (should use _ambient_write helper):"
    echo "$raw"
    FAIL=1
else
    echo "PASS: no raw ambient.jsonl appends in scripts/coord/"
fi

exit $FAIL
