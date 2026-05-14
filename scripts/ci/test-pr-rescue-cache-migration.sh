#!/usr/bin/env bash
# scripts/ci/test-pr-rescue-cache-migration.sh — INFRA-1109
#
# Verifies pr-rescue.sh prefers cache_lookup_pr over direct gh api per-PR.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PR_RESCUE="$REPO_ROOT/scripts/coord/pr-rescue.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$PR_RESCUE" ]] || fail "pr-rescue.sh missing"
grep -q 'INFRA-1109' "$PR_RESCUE" || fail "INFRA-1109 banner missing"
grep -q 'cache_lookup_pr' "$PR_RESCUE" || fail "doesn't call cache_lookup_pr"
grep -q 'lib/github_cache.sh' "$PR_RESCUE" || fail "doesn't source github_cache.sh"
# Verify the fallback path (chump_gh api) is still present
grep -q 'chump_gh api "repos/${REPO}/pulls/${PR_NUM}"' "$PR_RESCUE" \
    || fail "lost the chump_gh api fallback"
ok "static: cache_lookup_pr call + lib source + gh api fallback all present"

# Verify the cache call comes BEFORE the fallback (line ordering)
CACHE_LINE=$(grep -n 'cache_lookup_pr "\${PR_NUM}"' "$PR_RESCUE" | head -1 | cut -d: -f1)
FALLBACK_LINE=$(grep -n 'chump_gh api "repos/${REPO}/pulls/${PR_NUM}"' "$PR_RESCUE" | head -1 | cut -d: -f1)
[[ "$CACHE_LINE" -lt "$FALLBACK_LINE" ]] \
    || fail "cache_lookup_pr (line $CACHE_LINE) must come before fallback (line $FALLBACK_LINE)"
ok "cache_lookup_pr precedes chump_gh api fallback in PR loop"

# Verify the script syntactically parses (bash -n)
bash -n "$PR_RESCUE" || fail "pr-rescue.sh has syntax error after migration"
ok "pr-rescue.sh syntactically valid"

echo
echo "All INFRA-1109 pr-rescue-cache-migration tests passed."
