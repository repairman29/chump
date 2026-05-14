#!/usr/bin/env bash
# test-bot-merge-grep-c-fix.sh — INFRA-924
#
# Verifies that the DECOMP_CODEMOD and _cognition_touched grep-c assignments
# in bot-merge.sh use `|| true` (not `|| echo 0`) so that `grep -c` returning
# exit 1 (zero matches) doesn't produce "0\n0" and trigger arithmetic errors.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. No grep -c pipe with || echo 0 (produces double-zero on no-match)
if grep -qE "grep -cE.*\|\| echo 0|grep -c[^|]*\|\| echo 0" "$BM"; then
    fail "bot-merge.sh still has 'grep -c ... || echo 0' — replace with '|| true'"
fi
ok "No grep -c ... || echo 0 patterns found in bot-merge.sh"

# 2. _cognition_touched assignment uses || true
if ! grep -q "grep -cE.*|| true" "$BM"; then
    fail "_cognition_touched grep-cE assignment missing '|| true'"
fi
ok "_cognition_touched uses || true"

# 3. Functional check: simulate the zero-match case.
#    grep -c with no matches exits 1; with || true the result is just "0".
result=$(echo "some/file.rs" | grep -cE "^(src/cognition/)" || true)
if [[ "$result" == *$'\n'* ]]; then
    fail "Functional: zero-match grep -c with || true still produces multi-line: '$result'"
fi
if [[ "$result" != "0" ]]; then
    fail "Functional: expected '0', got '$result'"
fi
ok "Functional: zero-match grep -c || true produces single '0', no '0\n0'"

# 4. Arithmetic safety: the single "0" value works in [[ -gt 0 ]]
val=$(echo "" | grep -cE "nomatch" || true)
if [[ "${val:-0}" -gt 0 ]]; then
    fail "Expected val=0, comparison returned true unexpectedly"
fi
ok "Arithmetic: [[ \${val:-0} -gt 0 ]] works without syntax error when val='0'"

echo
echo "All INFRA-924 bot-merge grep-c double-echo tests passed."
