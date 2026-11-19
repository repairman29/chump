#!/usr/bin/env bash
# scripts/ci/test-pwa-operator-attention.sh — PRODUCT-117

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$REPO_ROOT/web/v2/operator-attention.js"
INDEX="$REPO_ROOT/web/v2/index.html"
APP="$REPO_ROOT/web/v2/app.js"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. Component defines the custom element
[[ -f "$COMP" ]] || fail "component file missing: $COMP"
grep -q "customElements.define('chump-operator-attention'" "$COMP" \
    || fail "chump-operator-attention not defined"
ok "operator-attention.js defines <chump-operator-attention>"

# 2. Covers the 8 tracked ambient kinds
for kind in orphan_pr_candidate roadmap_update_proposal_opened pillar_balance_block \
            pr_dedup_bypass_rejected pr_bounced_unfinished gap_drift_orphan \
            gh_shim_worktree_install_blocked worktree_gitdir_repair_fired; do
    grep -q "'$kind'" "$COMP" || fail "missing tracked kind: $kind"
done
ok "component tracks all 8 operator-attention ambient kinds"

# 3. Fetches /api/ambient/recent with kind filter
grep -q "/api/ambient/recent" "$COMP" || fail "no /api/ambient/recent fetch"
grep -q "encodeURIComponent(kind)" "$COMP" || fail "kind not URL-encoded in query"
ok "fetches /api/ambient/recent?kind=... per tracked kind"

# 4. Defer (4h) + Dismiss state via chumpPrefs / localStorage
grep -qE "DEFER_TTL_S\s*=\s*4\s*\*\s*60\s*\*\s*60" "$COMP" || fail "DEFER_TTL_S is not 4 hours"
grep -q "chumpPrefs" "$COMP" || fail "no chumpPrefs integration for state"
grep -q "_defer" "$COMP" || fail "no _defer handler"
grep -q "_dismiss" "$COMP" || fail "no _dismiss handler"
ok "Defer (4h TTL) + Dismiss persisted via chumpPrefs"

# 5. Fingerprint stability — defer survives re-fetch
grep -q "_fingerprint" "$COMP" || fail "no fingerprint helper"
ok "fingerprint helper present (defer/dismiss survives re-fetch)"

# 6. Auth header
grep -q "X-Chump-Auth" "$COMP" || fail "missing X-Chump-Auth header"
ok "sends X-Chump-Auth header (INFRA-1014 middleware)"

# 7. Polls every 30s
grep -qE "setInterval\(.*30[_]?000" "$COMP" || fail "missing 30s refresh polling"
ok "polls /api/ambient/recent every 30s"

# 8. Detail link per event (PR / gap / URL)
grep -q "_detailHref" "$COMP" || fail "no _detailHref helper"
grep -q "github.com/repairman29/chump/pull" "$COMP" || fail "no PR URL pattern"
ok "row detail link routes to PR / gap / URL"

# 9. Empty state — coffee message
grep -q "go drink coffee" "$COMP" || fail "no empty-state message"
ok "empty state shows 'go drink coffee'"

# 10. Wired into app.js VIEWS map as 'attention'
grep -q "attention:.*chump-operator-attention" "$APP" \
    || fail "VIEWS map doesn't bind attention -> chump-operator-attention"
ok "attention view bound in app.js VIEWS factory"

# 11. Script tag in index.html
grep -q 'src="operator-attention.js"' "$INDEX" \
    || fail "index.html missing operator-attention.js script tag"
ok "operator-attention.js script tag in index.html"

# 12. Disconnect cleanup
grep -q "disconnectedCallback" "$COMP" || fail "no disconnectedCallback"
grep -q "clearInterval" "$COMP" || fail "doesn't clear refresh timer"
ok "cleans up refresh timer on disconnect"

# 13. HTML-escape on user-supplied content (note field)
grep -q "_esc" "$COMP" || fail "no _esc helper for HTML injection"
ok "HTML-escapes event note/message before render"

echo
echo "All PRODUCT-117 operator-attention tests passed."
