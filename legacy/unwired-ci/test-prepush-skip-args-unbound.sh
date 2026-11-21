#!/usr/bin/env bash
# scripts/ci/test-prepush-skip-args-unbound.sh — INFRA-1316
#
# Regression test for the pre-push hook's bash-3.2 + `set -u` crash. Before
# the fix, `"${_SKIP_ARGS[@]}"` aborted with "unbound variable" when
# KNOWN_FLAKES.yaml had zero entries (the common case), and the subshell
# crash was misreported as "tests failed". The fix is the canonical
# `${arr[@]:+"${arr[@]}"}` idiom.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$HOOK" ]] || fail "pre-push hook source missing: $HOOK"

# 1. Every `"${_SKIP_ARGS[@]}"` occurrence MUST sit inside the `:+`
# guard. Standalone occurrences are the buggy form that crashes bash 3.2.
unsafe_lines=$(grep -nE '"\$\{_SKIP_ARGS\[@\]\}"' "$HOOK" | grep -vE ':\+' || true)
if [[ -n "$unsafe_lines" ]]; then
    fail "pre-push has unguarded \"\${_SKIP_ARGS[@]}\" deref (crashes bash 3.2): $unsafe_lines"
fi
ok "no unguarded \"\${_SKIP_ARGS[@]}\" deref in pre-push"

# 2. The safe idiom must appear.
if ! grep -qE '\$\{_SKIP_ARGS\[@\]:\+' "$HOOK"; then
    fail "pre-push must use \${_SKIP_ARGS[@]:+\"\${_SKIP_ARGS[@]}\"} idiom"
fi
ok "pre-push uses safe \${_SKIP_ARGS[@]:+...} idiom"

# 3. Functional repro: empty array deref must NOT crash with the safe form.
if ! bash -c 'set -u; arr=(); echo "ok ${arr[@]:+${arr[@]}}"' >/dev/null 2>&1; then
    fail "safe idiom unexpectedly crashes in this bash"
fi
ok "safe idiom doesn't crash on empty array under set -u"

# 4. Populated-array path: skip-args still pass through correctly.
out=$(bash -c 'set -u; arr=("--skip" "foo::bar"); printf "%s " "${arr[@]:+${arr[@]}}"' 2>&1)
if [[ "$out" != "--skip foo::bar " ]]; then
    fail "populated array doesn't expand correctly: got [$out]"
fi
ok "populated array expands to correct args"

# 5. Buggy form actually crashes (proves the original bug exists in vanilla bash 3.2).
if bash -c 'set -u; arr=(); echo "${arr[@]}"' 2>/dev/null; then
    : # bash 4+ might allow this — still fine; the fix is bash-3.2-safe regardless
    ok "vanilla bash here is lenient — safe idiom still required for macOS 3.2"
else
    ok "original buggy form crashes vanilla bash with set -u (regression baseline)"
fi

echo
echo "All INFRA-1316 pre-push regression assertions passed."
