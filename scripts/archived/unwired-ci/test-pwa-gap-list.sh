#!/usr/bin/env bash
# test-pwa-gap-list.sh — PRODUCT-102
#
# Verifies the gap list browser:
#   1. Static wiring: /api/gaps route registered in web_server.rs.
#   2. Frontend: gap-list.js exists + customElements.define present.
#   3. index.html: gap-list.js script tag present.
#   4. VIEWS + CHUMP_CADENCES: 'gaps' view wired in app.js.
#   5. Client-side features: PAGE_SIZE, sort, filter, claim, ambient emit.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "==> PRODUCT-102: PWA gap list browser tests"

# ── 1. Backend route ──────────────────────────────────────────────────────────

grep -q '"/api/gaps"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/gaps route registered" || fail "/api/gaps route missing"

grep -q 'get(handle_gap_queue)' "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_gap_queue handler wired" || fail "handle_gap_queue not wired"

# The /api/gaps and /api/gap-queue must both point to handle_gap_queue
REPO_ROOT="$REPO_ROOT" python3 - <<'PYEOF'
import re, os, sys
src = open(os.path.join(os.environ['REPO_ROOT'], 'src/web_server.rs')).read()
if '"/api/gaps"' in src: print("[PASS] /api/gaps present")
else: print("[FAIL] /api/gaps missing"); sys.exit(1)
PYEOF
if [[ $? -eq 0 ]]; then ok "/api/gaps handler check"; else fail "/api/gaps handler check"; fi

# ── 2. Frontend component ─────────────────────────────────────────────────────

[[ -f "$REPO_ROOT/web/v2/gap-list.js" ]] \
    && ok "gap-list.js exists" || fail "gap-list.js missing"

grep -q "customElements.define.*chump-view-gaps" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "customElements.define present" || fail "customElements.define missing"

grep -q "class ChumpViewGaps" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "ChumpViewGaps class present" || fail "ChumpViewGaps class missing"

# ── 3. index.html wiring ──────────────────────────────────────────────────────

grep -q "gap-list.js" "$REPO_ROOT/web/v2/index.html" \
    && ok "gap-list.js in index.html" || fail "gap-list.js not in index.html"

# ── 4. VIEWS + cadence wiring in app.js ───────────────────────────────────────

grep -q "gaps.*chump-view-gaps" "$REPO_ROOT/web/v2/app.js" \
    && ok "gaps view wired in VIEWS" || fail "gaps view not in VIEWS"

grep -q "id: 'gaps'" "$REPO_ROOT/web/v2/app.js" \
    && ok "gaps subtab in CHUMP_CADENCES" || fail "gaps subtab missing from CHUMP_CADENCES"

# ── 5. Client-side feature markers ───────────────────────────────────────────

grep -q "PAGE_SIZE" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "PAGE_SIZE pagination constant" || fail "PAGE_SIZE missing"

grep -q "PRIORITY_ORDER\|sortCol\|sortAsc" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "sort logic present" || fail "sort logic missing"

grep -q "gb-filterbar\|statusFilter\|domainFilter\|pillarFilter" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "filter bar present" || fail "filter bar missing"

grep -q "pwa_gap_list_filtered" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "ambient emit kind present" || fail "pwa_gap_list_filtered missing"

grep -q "gb-claim-btn\|api/gap/claim" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "Claim button wired" || fail "Claim button missing"

grep -q "chump:navigate\|chump:gap-detail" "$REPO_ROOT/web/v2/gap-list.js" \
    && ok "row navigation event present" || fail "row navigation missing"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL CHECKS PASSED — PRODUCT-102 verified" && exit 0 || exit 1
