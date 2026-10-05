#!/usr/bin/env bash
# pre-commit-grep-c-echo0-guard.sh — RESILIENT-281
#
# Rejects new instances of the `grep -c ... || echo 0` idiom in staged
# scripts/**. `grep -c` already prints "0" (and exits 1) on zero matches,
# so `|| echo 0` appends a SECOND line, e.g. $'0\n0'. Any numeric comparison
# fed by that value ([[ -x -gt 0 ]], (( x == 0 )), etc.) trips a bash
# "syntax error in expression" and silently skips the branch — a false PASS
# on -gt/-ge sites, a false FAIL on -eq 0 sites. Use `|| true` instead (grep
# already emitted the correct "0"); see RESILIENT-281 for the full sweep.
#
# Bypass: 'Grep-C-Echo0-Bypass: <one-sentence reason>' commit trailer.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

STAGED_SCRIPTS=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '^scripts/.*\.sh$' || true)
if [[ -z "$STAGED_SCRIPTS" ]]; then
    exit 0
fi

VIOLATIONS=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$REPO_ROOT/$f" ]] || continue
    hits=$(grep -nE 'grep -c[A-Za-z]*[^|]*\|\|[[:space:]]*echo[[:space:]]+"?'"'"'?0"?'"'"'?\b' "$REPO_ROOT/$f" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        VIOLATIONS+="$f:"$'\n'"$hits"$'\n'
    fi
done <<< "$STAGED_SCRIPTS"

if [[ -z "$VIOLATIONS" ]]; then
    exit 0
fi

echo "[grep-c-echo0-guard] found 'grep -c ... || echo 0' in staged scripts/:" >&2
echo "$VIOLATIONS" >&2

MSG_FILE="$(git rev-parse --git-common-dir)/COMMIT_EDITMSG"
if [[ -f "$MSG_FILE" ]] && grep -qE '^Grep-C-Echo0-Bypass:' "$MSG_FILE" 2>/dev/null; then
    reason="$(grep -E '^Grep-C-Echo0-Bypass:' "$MSG_FILE" | head -1 | sed 's/^Grep-C-Echo0-Bypass:[[:space:]]*//')"
    echo "[grep-c-echo0-guard] Bypassed: $reason" >&2
    exit 0
fi

echo "" >&2
echo "Replace 'grep -c PAT FILE || echo 0' with 'grep -c PAT FILE || true' —" >&2
echo "grep -c already prints the correct '0' on zero matches; '|| echo 0' just" >&2
echo "appends a duplicate line that breaks numeric comparisons downstream." >&2
echo "To bypass: add 'Grep-C-Echo0-Bypass: <one-sentence reason>' to commit body." >&2
exit 1
