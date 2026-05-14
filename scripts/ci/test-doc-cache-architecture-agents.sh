#!/usr/bin/env bash
# scripts/ci/test-doc-cache-architecture-agents.sh — INFRA-1135
#
# Companion to scripts/ci/test-doc-cache-architecture.sh (INFRA-1132 which
# checks CLAUDE.md + scripts/coord/README.md). This test asserts the same
# three sections also exist in AGENTS.md (the tool-agnostic doctrine read
# by non-Claude-Code agents like Sonnet via opencode, Gemini reviewer, etc.)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS_MD="$REPO_ROOT/AGENTS.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$AGENTS_MD" ]] || fail "AGENTS.md missing"

# Cache-first reads section
grep -q '## Cache-first reads (INFRA-1081' "$AGENTS_MD" \
    || fail "AGENTS.md missing 'Cache-first reads' section"
grep -q 'cache_lookup_pr' "$AGENTS_MD" \
    || fail "AGENTS.md missing cache_lookup_pr reference"
grep -q 'cache_query_behind_prs' "$AGENTS_MD" \
    || fail "AGENTS.md missing cache_query_behind_prs reference"
grep -q 'cache_lookup_checks' "$AGENTS_MD" \
    || fail "AGENTS.md missing cache_lookup_checks reference"
ok "AGENTS.md: Cache-first reads section + all 3 helper names referenced"

# Call criticality section
grep -q '## Call criticality (INFRA-1080' "$AGENTS_MD" \
    || fail "AGENTS.md missing 'Call criticality' section"
grep -q 'CHUMP_GH_CALL_CRITICALITY' "$AGENTS_MD" \
    || fail "AGENTS.md missing CHUMP_GH_CALL_CRITICALITY env var"
ok "AGENTS.md: Call criticality section + env var documented"

# GraphQL exhaustion handling section
grep -q '## GraphQL exhaustion handling' "$AGENTS_MD" \
    || fail "AGENTS.md missing GraphQL exhaustion handling section"
grep -q 'CHUMP_GH_MAX_CALLS_PER_MIN' "$AGENTS_MD" \
    || fail "AGENTS.md missing self-throttle knob"
grep -q 'api-cost-leaderboard.sh' "$AGENTS_MD" \
    || fail "AGENTS.md doesn't point at leaderboard for diagnosis"
ok "AGENTS.md: GraphQL exhaustion section + leaderboard pointer"

# Tool-agnostic check: AGENTS.md should NOT reference Claude-Code-specific
# things in the new sections (smoke check — no claude_code references in
# the diff region).
NEW_SECTIONS="$(awk '/## Cache-first reads/,/## Where to find docs/' "$AGENTS_MD")"
echo "$NEW_SECTIONS" | grep -qiE "claude.?code|anthropic.?sdk" \
    && fail "new AGENTS.md sections reference Claude-Code (should be tool-agnostic)"
ok "new AGENTS.md sections are tool-agnostic (no Claude-Code-specific refs)"

echo
echo "All INFRA-1135 doc-cache-architecture-agents tests passed."
