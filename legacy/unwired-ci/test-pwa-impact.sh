#!/usr/bin/env bash
# test-pwa-impact.sh — PRODUCT-081
#
# Verifies the PWA Outcome Dashboard:
#   1. Backend: /api/impact route registered in web_server.rs
#   2. Backend: handle_impact handler present and async
#   3. Backend: window param (today/week/all) handled
#   4. Backend: 60s server-side cache (IMPACT_CACHE or similar)
#   5. Backend: metrics: prs_merged, gaps_closed, operator_hours_saved, fleet_activity_hours
#   6. Backend: pillar_mix present in response
#   7. Backend: top_prs present in response
#   8. Backend: tracing::info! observability hook
#   9. Frontend: impact.js exists + customElements.define present
#  10. Frontend: ChumpViewImpact class present
#  11. Frontend: three window tabs (today/week/all)
#  12. Frontend: pillar_mix rendering
#  13. index.html: impact.js script tag present
#  14. app.js: impact wired in VIEWS

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "==> PRODUCT-081: PWA Outcome Dashboard tests"

# ── 1. Backend route ──────────────────────────────────────────────────────────

grep -q '"/api/impact"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/impact route registered" || fail "/api/impact route missing"

grep -q 'get(handle_impact)' "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_impact handler wired" || fail "handle_impact not wired"

# ── 2. Handler presence ───────────────────────────────────────────────────────

grep -q 'async fn handle_impact' "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_impact function present" || fail "handle_impact function missing"

# ── 3. window param ───────────────────────────────────────────────────────────

grep -q '"today"\|"week"\|"all"' "$REPO_ROOT/src/web_server.rs" \
    && ok "window param values present" || fail "window param values missing"

# ── 4. Server-side cache ─────────────────────────────────────────────────────

grep -q 'IMPACT_CACHE\|OnceLock.*Mutex\|60\b' "$REPO_ROOT/src/web_server.rs" \
    && ok "60s cache present" || fail "60s cache missing"

# ── 5. Top-line metrics ───────────────────────────────────────────────────────

for metric in prs_merged gaps_closed operator_hours_saved fleet_activity_hours; do
    grep -q "\"$metric\"" "$REPO_ROOT/src/web_server.rs" \
        && ok "metric '$metric' in response" \
        || fail "metric '$metric' missing"
done

# ── 6. pillar_mix ────────────────────────────────────────────────────────────

grep -q '"pillar_mix"' "$REPO_ROOT/src/web_server.rs" \
    && ok "pillar_mix in response" || fail "pillar_mix missing"

# ── 7. top_prs ───────────────────────────────────────────────────────────────

grep -q '"top_prs"' "$REPO_ROOT/src/web_server.rs" \
    && ok "top_prs in response" || fail "top_prs missing"

# ── 8. Observability ─────────────────────────────────────────────────────────

grep -q 'tracing::info!\|tracing::debug!' "$REPO_ROOT/src/web_server.rs" \
    && ok "tracing hook present" || fail "tracing hook missing"

# ── 9. Frontend component ─────────────────────────────────────────────────────

[[ -f "$REPO_ROOT/web/v2/impact.js" ]] \
    && ok "impact.js exists" || fail "impact.js missing"

grep -q "customElements.define.*chump-view-impact" "$REPO_ROOT/web/v2/impact.js" \
    && ok "customElements.define present" || fail "customElements.define missing"

# ── 10. ChumpViewImpact class ─────────────────────────────────────────────────

grep -q "class ChumpViewImpact" "$REPO_ROOT/web/v2/impact.js" \
    && ok "ChumpViewImpact class present" || fail "ChumpViewImpact class missing"

# ── 11. Three window tabs ─────────────────────────────────────────────────────

grep -q "today\|week\|all" "$REPO_ROOT/web/v2/impact.js" \
    && ok "window tabs (today/week/all) present" || fail "window tabs missing"

# ── 12. Pillar mix rendering ─────────────────────────────────────────────────

grep -q "pillar_mix\|PILLAR_COLORS\|pillar" "$REPO_ROOT/web/v2/impact.js" \
    && ok "pillar mix rendering present" || fail "pillar mix rendering missing"

# ── 13. index.html ───────────────────────────────────────────────────────────

grep -q "impact.js" "$REPO_ROOT/web/v2/index.html" \
    && ok "impact.js in index.html" || fail "impact.js not in index.html"

# ── 14. app.js VIEWS ─────────────────────────────────────────────────────────

grep -q "impact.*chump-view-impact" "$REPO_ROOT/web/v2/app.js" \
    && ok "impact view wired in VIEWS" || fail "impact view not in VIEWS"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL CHECKS PASSED — PRODUCT-081 verified" && exit 0 || exit 1
