#!/usr/bin/env bash
# scripts/ci/test-cold-water-push-safety.sh — META-272
#
# Guards against the detached-HEAD push trap that stranded RED_LETTER
# Issues #12/#13 for 50 commits: `git push origin main` pushes the local
# branch named `main`, not the commit just made, so a detached-HEAD sandbox
# silently pushes nothing new. docs/agents/cold-water.md must push HEAD
# explicitly and verify the push landed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$REPO_ROOT/docs/agents/cold-water.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$DOC" ] || fail "docs/agents/cold-water.md not found"

# The unsafe pattern must not reappear inside a shell code fence (prose
# mentioning it as a cautionary example is fine — only runnable instructions
# matter here).
if awk '/^```bash/{f=1;next} /^```/{f=0} f' "$DOC" \
    | grep -E 'git push origin main($|[^:])' >/dev/null; then
    fail "docs/agents/cold-water.md contains unsafe 'git push origin main' inside a bash block (must push HEAD explicitly: 'git push origin HEAD:main')"
fi

grep -q 'git push origin HEAD:main' "$DOC" \
    || fail "docs/agents/cold-water.md missing safe 'git push origin HEAD:main' push instruction"

grep -q 'git ls-remote origin main' "$DOC" \
    || fail "docs/agents/cold-water.md missing post-push verification against origin/main"

ok "cold-water.md pushes HEAD explicitly and verifies the push landed on origin/main"
