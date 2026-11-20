#!/usr/bin/env bash
# test-error-message-doc-links.sh — INFRA-590
#
# Assert that each known high-frequency error class has:
#   1. A matching HTML anchor (<a id="..."></a>) in docs/process/CLAUDE_GOTCHAS.md
#   2. At least one script that emits a "See: docs/process/CLAUDE_GOTCHAS.md#<anchor>" reference
#
# Exit 0 = all checks pass. Exit 1 = one or more anchors missing or unlinked.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOTCHAS="$REPO_ROOT/docs/process/CLAUDE_GOTCHAS.md"

PASS=0
FAIL=0

ok()   { printf '  OK:   %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

# Known error classes (anchor:description pairs, parallel arrays)
ANCHORS=(
    "error-binary-wedge"
    "error-gap-collision"
    "error-missing-closed-pr"
    "error-wrong-worktree"
)
DESCS=(
    "chump binary wedged by syspolicyd"
    "gap already claimed or open PR exists"
    "status:done committed without a real PR number"
    "refusing to claim gap in the main worktree"
)

echo "=== test-error-message-doc-links.sh ==="
echo ""

# ── Check 1: each anchor exists in CLAUDE_GOTCHAS.md ─────────────────────────
echo "Check 1: anchors present in docs/process/CLAUDE_GOTCHAS.md"
for i in "${!ANCHORS[@]}"; do
    anchor="${ANCHORS[$i]}"
    desc="${DESCS[$i]}"
    if grep -q "id=\"${anchor}\"" "$GOTCHAS" 2>/dev/null; then
        ok "anchor '#${anchor}' found  (${desc})"
    else
        fail "anchor '#${anchor}' MISSING from CLAUDE_GOTCHAS.md  (${desc})"
    fi
done
echo ""

# ── Check 2: each anchor is referenced from at least one script ──────────────
echo "Check 2: anchors referenced in scripts/ (CLAUDE_GOTCHAS.md#<anchor>)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

for i in "${!ANCHORS[@]}"; do
    anchor="${ANCHORS[$i]}"
    desc="${DESCS[$i]}"
    if grep -rq "CLAUDE_GOTCHAS\.md#${anchor}" "$SCRIPTS_DIR" 2>/dev/null; then
        ok "anchor '#${anchor}' referenced in scripts/  (${desc})"
    else
        fail "anchor '#${anchor}' NOT referenced by any script under scripts/  (${desc})"
    fi
done
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL ))
echo "Results: ${PASS}/${TOTAL} passed"
if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "To fix:"
    echo "  - Missing anchor in CLAUDE_GOTCHAS.md: add <a id=\"<anchor>\"></a> before the relevant section"
    echo "  - Missing script reference: add 'See: docs/process/CLAUDE_GOTCHAS.md#<anchor>' to the error output"
    exit 1
fi
echo "All checks passed."
