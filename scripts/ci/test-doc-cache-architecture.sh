#!/usr/bin/env bash
# scripts/ci/test-doc-cache-architecture.sh — INFRA-1132
#
# Static check that the doc surfaces announcing the INFRA-1081 cache + INFRA-1080
# criticality conventions are in place. Catches regressions where someone
# edits CLAUDE.md or scripts/coord/README.md and accidentally removes the
# new sections.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
COORD_README="$REPO_ROOT/scripts/coord/README.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# CLAUDE.md sections
grep -q '## Cache-first reads (INFRA-1081' "$CLAUDE_MD" \
    || fail "CLAUDE.md missing 'Cache-first reads' section"
grep -q 'cache_lookup_pr' "$CLAUDE_MD" || fail "CLAUDE.md missing cache_lookup_pr reference"
grep -q 'cache_query_behind_prs' "$CLAUDE_MD" || fail "CLAUDE.md missing cache_query_behind_prs reference"
grep -q 'cache_lookup_checks' "$CLAUDE_MD" || fail "CLAUDE.md missing cache_lookup_checks reference"
ok "CLAUDE.md: Cache-first reads section + all 3 helper names referenced"

grep -q '## Call criticality (INFRA-1080' "$CLAUDE_MD" \
    || fail "CLAUDE.md missing 'Call criticality' section"
grep -q 'CHUMP_GH_CALL_CRITICALITY' "$CLAUDE_MD" \
    || fail "CLAUDE.md missing CHUMP_GH_CALL_CRITICALITY env var"
ok "CLAUDE.md: Call criticality section + env var documented"

grep -q '## GraphQL exhaustion handling' "$CLAUDE_MD" \
    || fail "CLAUDE.md missing GraphQL exhaustion handling section"
grep -q 'CHUMP_GH_MAX_CALLS_PER_MIN' "$CLAUDE_MD" \
    || fail "CLAUDE.md missing self-throttle knob"
grep -q 'api-cost-leaderboard.sh' "$CLAUDE_MD" \
    || fail "CLAUDE.md doesn't point at leaderboard for diagnosis"
ok "CLAUDE.md: GraphQL exhaustion section + leaderboard pointer"

# coord/README.md sections
grep -q '## Cache lib (`lib/github_cache.sh`)' "$COORD_README" \
    || fail "coord/README.md missing Cache lib section"
grep -q 'cache_lookup_pr' "$COORD_README" || fail "coord/README.md missing cache_lookup_pr"
grep -q 'cache_query_behind_prs' "$COORD_README" || fail "coord/README.md missing cache_query_behind_prs"
grep -q 'cache_lookup_checks' "$COORD_README" || fail "coord/README.md missing cache_lookup_checks"
ok "coord/README.md: Cache lib section + all 3 helpers documented"

grep -q '## Auth-tier map' "$COORD_README" || fail "coord/README.md missing Auth-tier section"
grep -q 'AUTH_AUDIT.md' "$COORD_README" || fail "coord/README.md doesn't link AUTH_AUDIT.md"
ok "coord/README.md: Auth-tier map section + AUTH_AUDIT.md pointer"

echo
echo "All INFRA-1132 doc-cache-architecture tests passed."
