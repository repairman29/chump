#!/usr/bin/env bash
# max-loc-lint.sh — INFRA-4875 (INFRA-1965 slice)
#
# Fails if any tracked `.rs` file exceeds MAX_LOC lines, unless it's listed
# in the allowlist (pre-existing files that predate this gate). New files
# and existing files not on the allowlist must stay under the limit.
#
# Usage:
#   bash scripts/ci/max-loc-lint.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

MAX_LOC="${CHUMP_MAX_LOC:-500}"
ALLOWLIST="$REPO_ROOT/scripts/ci/max-loc-allowlist.txt"

mapfile -t ALLOWED < <(grep -v '^\s*#' "$ALLOWLIST" 2>/dev/null | grep -v '^\s*$')

is_allowed() {
    local target="$1"
    for entry in "${ALLOWED[@]}"; do
        [[ "$target" == "$entry" ]] && return 0
    done
    return 1
}

VIOLATIONS=0
while IFS= read -r -d '' file; do
    rel="${file#./}"
    lines=$(wc -l < "$file")
    if [[ "$lines" -gt "$MAX_LOC" ]] && ! is_allowed "$rel"; then
        echo "max-loc-lint: $rel has $lines lines (max $MAX_LOC)" >&2
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done < <(git ls-files -z -- '*.rs')

if [[ "$VIOLATIONS" -gt 0 ]]; then
    echo "max-loc-lint: $VIOLATIONS file(s) exceed $MAX_LOC lines and are not on the allowlist" >&2
    echo "max-loc-lint: split the file, or if pre-existing, add it to scripts/ci/max-loc-allowlist.txt" >&2
    exit 1
fi

echo "max-loc-lint: OK (no .rs file over $MAX_LOC lines outside the allowlist)"
exit 0
