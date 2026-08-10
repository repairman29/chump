#!/usr/bin/env bash
# pre-commit-grep-c-echo0.sh — RESILIENT-281
#
# Refuses staged shell additions of the `grep -c ... || echo 0` idiom.
#
# Why: `grep -c` ALWAYS prints its match count to stdout, even on zero
# matches — but it also exits 1 on zero matches. `cmd || echo 0` fires on
# that nonzero exit and appends a SECOND "0" line, so the captured value
# is the two-line string $'0\n0' instead of "0". Any numeric comparison
# against that value ($'0\n0' -gt 0 / -eq 0 / etc.) throws a bash
# "syntax error in expression" to stderr and silently skips the branch —
# so the assertion can never fire in either direction. See RESILIENT-281
# for the story of a real DEAD test assertion this idiom produced
# (scripts/ci/test-curator-supervisor.sh, fixed in PR #3562).
#
# The fix is `|| true` (or no fallback at all) — grep -c's own zero-match
# output is already the "0" you want; you never need to substitute one.
#
# Bypass: append `# chump-fmt: grep-c-echo0-ok` to the offending line, or
# suppress the whole guard with CHUMP_GREP_C_ECHO0_CHECK=0 (add a
# `Grep-C-Echo0-Bypass: <reason>` trailer to the commit body).

set -uo pipefail

if [[ "${CHUMP_GREP_C_ECHO0_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 0

STAGED_SH=$(git diff --cached --name-only --diff-filter=ACM -- '*.sh' 2>/dev/null || true)
[[ -z "$STAGED_SH" ]] && exit 0

violations=()
while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    # Only look at newly-added lines so pre-existing (already-scanned-once,
    # or intentionally-excluded meta/doc) lines don't re-trip the guard.
    added_lines="$(git diff --cached -U0 -- "$path" | awk '
        /^@@/ { match($0, /\+[0-9]+/); n = substr($0, RSTART+1, RLENGTH-1); next }
        /^\+[^+]/ { print n; n++ }
    ')"
    [[ -z "$added_lines" ]] && continue
    while IFS= read -r lineno; do
        [[ -z "$lineno" ]] && continue
        line="$(sed -n "${lineno}p" "$path")"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *'chump-fmt: grep-c-echo0-ok'* ]] && continue
        if [[ "$line" == *'grep -c'* && "$line" == *'|| echo 0'* ]]; then
            violations+=("$path:$lineno: $(echo "$line" | sed -e 's/^[[:space:]]*//')")
        fi
    done <<< "$added_lines"
done <<< "$STAGED_SH"

if [[ ${#violations[@]} -eq 0 ]]; then
    exit 0
fi

echo "" >&2
echo "──────────────────────────────────────────────────────────────" >&2
echo "❌ RESILIENT-281 grep-c-echo0 guard blocked this commit." >&2
echo "" >&2
echo "'grep -c ... || echo 0' produces the two-line value \$'0\\n0' on the" >&2
echo "zero-match path (grep -c prints its count AND exits 1), which throws" >&2
echo "a silent bash 'syntax error in expression' on any numeric comparison." >&2
echo "" >&2
echo "Violations:" >&2
for v in "${violations[@]}"; do
    echo "  $v" >&2
done
echo "" >&2
echo "Fix: replace '|| echo 0' with '|| true' (grep -c already prints \"0\"" >&2
echo "on zero matches; you never need to substitute one)." >&2
echo "" >&2
echo "Whitelist a line (rare — e.g. documentation of the anti-pattern):" >&2
echo "  append  # chump-fmt: grep-c-echo0-ok" >&2
echo "" >&2
echo "Bypass entire guard once (requires Grep-C-Echo0-Bypass: trailer):" >&2
echo "  CHUMP_GREP_C_ECHO0_CHECK=0 git commit ..." >&2
echo "──────────────────────────────────────────────────────────────" >&2
exit 1
