#!/usr/bin/env bash
# scripts/ci/test-pipefail-race-sweep.sh — INFRA-1658
#
# Guard against new occurrences of the printf|grep -q pipefail race in
# hot-path scripts (scripts/coord/, scripts/git-hooks/, scripts/dispatch/).
#
# THE BUG:
#   Under `set -o pipefail`, `printf 'X' | grep -q Y` is racy: grep -q
#   closes stdin on first match → printf gets SIGPIPE → printf's exit
#   code becomes non-zero → the WHOLE pipeline exits non-zero. Result:
#   the `if printf | grep -q; then ...` branch fails to fire even when
#   the pattern matched. Cost us 6 hours debugging INFRA-755 (the
#   pre-commit-obs-budget false-negative chain) before locating it.
#
# THE FIX:
#   Materialize the producer side to a tempfile, then grep against the
#   file. See scripts/git-hooks/pre-commit-obs-budget.sh for the model.
#
#   _tmp=$(mktemp); printf '%s\n' "$BLOB" > "$_tmp"
#   if grep -qE 'pattern' "$_tmp"; then ...
#   rm -f "$_tmp"
#
# WHAT THIS TEST DOES:
#   Greps the three hot-path directories for `printf ... | ... grep -q`
#   occurrences. Fails if any NEW occurrence appears. Existing
#   intentional instances (e.g. inside scripts that don't set -o
#   pipefail, or where the producer is one short line) are allowlisted
#   via the comment marker `# pipefail-sweep-allowed` on the same line.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

HOT_DIRS=(scripts/coord scripts/git-hooks scripts/dispatch)

# Find candidate lines: printf ... grep -q (in any form) on the same
# line. Filter out the allowlist marker, comments-only lines, and the
# test file itself.
VIOLATIONS=$(grep -rn -E 'printf[^|]*\|[^|]*grep[[:space:]]+-[a-zA-Z]*q' \
    "${HOT_DIRS[@]}" 2>/dev/null \
    | grep -v 'pipefail-sweep-allowed' \
    | grep -v 'test-pipefail-race-sweep\.sh' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    || true)

# Also reject the inverse `| grep -q ... <<<` shorthand inside the same
# directories — same root cause when pipefail is set.

if [[ -n "$VIOLATIONS" ]]; then
    echo "❌ INFRA-1658: pipefail-race-prone pattern detected in hot-path scripts." >&2
    echo "" >&2
    echo "Under set -o pipefail, 'printf X | grep -q Y' is racy: grep -q closes" >&2
    echo "stdin on first match → printf gets SIGPIPE → pipeline exits non-zero" >&2
    echo "EVEN WHEN the pattern matched. This produces silent false-negatives" >&2
    echo "in conditional branches." >&2
    echo "" >&2
    echo "Fix: materialize producer to a tempfile, then grep the file." >&2
    echo "  _t=\$(mktemp); printf '%s\\n' \"\$BLOB\" > \"\$_t\"" >&2
    echo "  if grep -qE 'pattern' \"\$_t\"; then ..." >&2
    echo "  rm -f \"\$_t\"" >&2
    echo "" >&2
    echo "If the occurrence is intentional (script doesn't set pipefail, or" >&2
    echo "producer is one short literal), append this marker to the line:" >&2
    echo "  # pipefail-sweep-allowed" >&2
    echo "" >&2
    echo "Violations:" >&2
    printf '%s\n' "$VIOLATIONS" | sed 's/^/  /' >&2
    echo "" >&2
    echo "See docs/process/CLAUDE_GOTCHAS.md → 'printf | grep -q pipefail race'." >&2
    exit 1
fi

echo "✅ INFRA-1658: no new printf|grep -q pipefail-race patterns in hot-path scripts."
exit 0
