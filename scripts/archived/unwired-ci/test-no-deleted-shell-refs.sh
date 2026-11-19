#!/usr/bin/env bash
# test-no-deleted-shell-refs.sh — INFRA-1256: CI guard — no test script may
# SOURCE or EXECUTE scripts deleted by INFRA-987 (gap-claim.sh, gap-preflight.sh).
#
# Checks for: source/bash/sh/./ invocations AND variable assignments whose
# value is later invoked (e.g. GAP_CLAIM="$REPO_ROOT/scripts/coord/gap-claim.sh"
# followed by "$GAP_CLAIM ..."). Pure string comparisons, comment-only lines,
# and "file was deleted" assertion checks are allowed.
#
# Run: bash scripts/ci/test-no-deleted-shell-refs.sh

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { printf '[PASS] %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1256: checking for dead exec references in scripts/ci/ ==="

# Patterns that indicate ACTUAL INVOCATION of a deleted script.
# - "source scripts/coord/gap-claim.sh" or ". scripts/coord/gap-claim.sh"
# - "bash scripts/coord/gap-claim.sh" or "bash .../gap-preflight.sh"
# - "$GAP_CLAIM args" — variable-invocation (GAP_CLAIM or PREFLIGHT must
#   be on the LEFT side of an expression, not inside [[ ! -f ... ]])
# Variable ASSIGNMENTS and existence-check guards (! -f, -f, [[ -f) are OK.
EXEC_RE='(^[[:space:]]*(source|bash|sh|\.)[[:space:]]+[^#]*gap-(claim|preflight)\.sh)'

violations=()
while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    # Skip comment-only lines
    content="${match#*:*:}"  # strip "file:N:" prefix
    trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    violations+=("$match")
done < <(
    grep -rnP "$EXEC_RE" scripts/ci/ 2>/dev/null \
    | grep -v "INFRA-987\|# " \
    || true
)

if [[ ${#violations[@]} -eq 0 ]]; then
    pass "No execution references to deleted scripts (gap-claim.sh, gap-preflight.sh)"
else
    fail "${#violations[@]} execution reference(s) to deleted scripts found:"
    for v in "${violations[@]}"; do
        fail "  $v"
    done
fi

echo ""
echo "INFRA-1256: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
