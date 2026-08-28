#!/usr/bin/env bash
# scripts/ci/test-operator-attention-daemon-outcomes.sh — META-193
#
# Verifies the PWA operator-attention queue surfaces pr-shepherd-daemon
# (META-180) UNKNOWN / DIRTY / BLOCKED_REAL_FAIL classifications and
# explicitly excludes MERGEABLE / BLOCKED_GREEN (auto-rebased/auto-armed
# outcomes should stay quiet — escalating them would be noise).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$REPO_ROOT/web/v2/operator-attention.js"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$COMP" ]] || fail "component file missing: $COMP"

# 1. pr_classified is a tracked kind
grep -q "kind: 'pr_classified'" "$COMP" || fail "pr_classified not tracked"
ok "pr_classified tracked"

# 2. escalated classifications present in the filter
for cls in UNKNOWN DIRTY BLOCKED_REAL_FAIL; do
    grep -q "'$cls'" "$COMP" || fail "missing escalated classification: $cls"
done
ok "UNKNOWN, DIRTY, BLOCKED_REAL_FAIL are escalated"

# 3. MERGEABLE / BLOCKED_GREEN must NOT appear inside the pr_classified filter
#    array (they're excluded by omission — assert the filter array itself
#    doesn't list them, which would defeat the exclusion).
FILTER_LINE="$(grep -n "filter: (e) =>" "$COMP" | head -1 | cut -d: -f1)"
[[ -n "$FILTER_LINE" ]] || fail "no filter function found for pr_classified"
FILTER_TEXT="$(sed -n "${FILTER_LINE}p" "$COMP")"
if echo "$FILTER_TEXT" | grep -q "MERGEABLE"; then
    fail "MERGEABLE must not be in the escalation allowlist"
fi
if echo "$FILTER_TEXT" | grep -q "BLOCKED_GREEN"; then
    fail "BLOCKED_GREEN must not be in the escalation allowlist"
fi
ok "MERGEABLE / BLOCKED_GREEN excluded from escalation filter"

# 4. auto-rebased outcomes (pr_action_taken action=rebase) are not tracked at all
if grep -q "kind: 'pr_action_taken'" "$COMP"; then
    fail "pr_action_taken (covers auto-rebase) must not be escalated wholesale"
fi
ok "pr_action_taken (auto-rebase outcomes) not escalated"

# 5. refresh() applies the per-kind filter before mapping events
grep -q "typeof filter === 'function'" "$COMP" || fail "refresh() doesn't apply per-kind filter"
ok "refresh() applies per-kind sub-filter"

echo
echo "All META-193 daemon-outcome escalation tests passed."
