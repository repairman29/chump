#!/usr/bin/env bash
# INFRA-1223: lint gate — refuse new direct `gh pr merge --auto` callers.
#
# Today's user-account multi-hour secondary-mutation gag is caused by fleet
# scripts firing `gh pr merge --auto` from loops/per-poll handlers WITHOUT
# going through scripts/coord/auto-merge-armer.sh. The armer enforces 5s
# spacing + 60/120/240s backoff on secondary rate limit; bypassing it is
# the dominant burn path.
#
# This script greps scripts/ for `gh pr merge ... --auto` and fails when
# the call site is anywhere OTHER than:
#   - scripts/coord/auto-merge-armer.sh (the one legitimate caller)
#   - test fixtures (test-*.sh)
#   - documentation/comment references (lines starting with `#` or inside
#     stderr/operator-instruction strings like `red "..."`)
#
# Run from repo root or any worktree:
#   scripts/ci/test-no-direct-auto-merge-arm.sh
#
# Wire as a CI gate in .github/workflows/ci.yml; also runs cheap enough to
# be a pre-commit advisory.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

VIOLATIONS=0
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Grep `gh pr merge` lines that include --auto. Restrict to scripts/.
# Use --include to filter; -n for line numbers; -E for regex alternation.
grep -rEn 'gh pr merge[^|;]*--auto' scripts/ \
    --include='*.sh' --include='*.py' \
    2>/dev/null > "$TMP" || true

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    file="${line%%:*}"
    rest="${line#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"

    # Allow-list: the centralized armer itself.
    if [[ "$file" == "scripts/coord/auto-merge-armer.sh" ]]; then
        continue
    fi

    # Allow-list: test fixtures.
    base="${file##*/}"
    if [[ "$base" == test-* ]]; then
        continue
    fi

    # Strip leading whitespace; if the line starts with `#` it's a comment.
    trimmed="${content#"${content%%[![:space:]]*}"}"
    if [[ "$trimmed" == "#"* ]]; then
        continue
    fi

    # Skip operator-instruction strings (printed to operator, not executed).
    # Heuristic: the `gh pr merge --auto` substring is inside a quoted
    # string passed to a logging function like `red`/`echo`/`info`/`say`.
    # Match common patterns: `red "..."`, `echo "..."`, `info "..."`.
    if echo "$trimmed" | grep -qE '^(red|green|yellow|info|log|say|echo|warn|err)[[:space:]]+["'"'"']'; then
        continue
    fi

    # Skip if the gh substring appears inside a heredoc body marker line
    # (the EOF/PYEOF/etc form). Heuristic: line ends with a heredoc
    # terminator pattern. Cheap fallback: skip lines that are pure string
    # literals quoting an operator-readable shell snippet.
    if echo "$trimmed" | grep -qE '^["'"'"']'; then
        continue
    fi

    # Skip documentation placeholders — lines containing <PR#>, <N>, <ID>,
    # <PR>, <NUMBER>, <branch>, etc. (angle-bracket placeholders). Real
    # shell wouldn't use those; they're operator-readable help text.
    if echo "$trimmed" | grep -qE '<[A-Z][A-Z#_-]*>|<[a-z][a-z_-]+>'; then
        continue
    fi

    echo "[lint] FAIL: ${file}:${lineno}: direct \`gh pr merge --auto\` call" >&2
    echo "[lint]    ${trimmed}" >&2
    echo "[lint]    Route through scripts/coord/auto-merge-armer.sh instead:" >&2
    echo "[lint]      \"\${REPO_ROOT}/scripts/coord/auto-merge-armer.sh\" --pr <N>" >&2
    echo "[lint]    The armer enforces 5s spacing + secondary-rate-limit backoff." >&2
    echo "[lint]    See CLAUDE.md \"Cache-first reads\" / INFRA-1223 for context." >&2
    VIOLATIONS=$((VIOLATIONS + 1))
done < "$TMP"

if [[ $VIOLATIONS -gt 0 ]]; then
    echo "" >&2
    echo "[lint] $VIOLATIONS direct \`gh pr merge --auto\` violations. Fix above." >&2
    exit 1
fi

echo "[lint] OK — no direct \`gh pr merge --auto\` callers outside auto-merge-armer.sh"
exit 0
