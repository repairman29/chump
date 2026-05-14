#!/usr/bin/env bash
# CI test for PRODUCT-090: GET /api/health/pillars + pillar-health web component.
#
# Tests:
#   1. handle_health_pillars function defined in web_server.rs
#   2. /api/health/pillars route registered in router
#   3. pillar-health.js component exists and polls correct endpoint
#   4. <chump-pillar-health> wired into PWA index.html
#   5. per-pillar fields (grade, pickable_count, p0_count, slo_breach) in response

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WEB_SERVER="${REPO_ROOT}/src/web_server.rs"
PILLAR_JS="${REPO_ROOT}/web/v2/pillar-health.js"
INDEX="${REPO_ROOT}/web/v2/index.html"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }

echo "[test-pillar-dashboard] PRODUCT-090 — 4-pillar health dashboard"

# ── 1. Handler defined ────────────────────────────────────────────────────────
echo
echo "[1. handle_health_pillars defined]"
if grep -q "async fn handle_health_pillars" "$WEB_SERVER"; then
    ok "handle_health_pillars function present"
else
    fail "handle_health_pillars not found in web_server.rs"
fi

# ── 2. Route registered ───────────────────────────────────────────────────────
echo
echo "[2. /api/health/pillars route registered]"
if grep -q '"/api/health/pillars"' "$WEB_SERVER"; then
    ok "/api/health/pillars route registered in router"
else
    fail "/api/health/pillars route missing from router"
fi

# ── 3. pillar-health.js component polls correct endpoint ─────────────────────
echo
echo "[3. pillar-health.js polls /api/health/pillars]"
if [[ -f "$PILLAR_JS" ]]; then
    if grep -q "health/pillars" "$PILLAR_JS"; then
        ok "pillar-health.js fetches /api/health/pillars"
    else
        fail "pillar-health.js does not reference /api/health/pillars"
    fi
else
    fail "web/v2/pillar-health.js not found"
fi

# ── 4. <chump-pillar-health> in index.html ────────────────────────────────────
echo
echo "[4. <chump-pillar-health> wired into index.html]"
if [[ -f "$INDEX" ]] && grep -q "chump-pillar-health" "$INDEX"; then
    ok "<chump-pillar-health> element present in index.html"
else
    fail "<chump-pillar-health> missing from web/v2/index.html"
fi

# ── 5. Per-pillar response fields in handler ─────────────────────────────────
echo
echo "[5. per-pillar fields in JSON response]"
if grep -q '"pickable_count"' "$WEB_SERVER" && \
   grep -q '"slo_breach"' "$WEB_SERVER" && \
   grep -q '"fleet_grade"' "$WEB_SERVER"; then
    ok "pickable_count, slo_breach, fleet_grade fields present in response"
else
    fail "per-pillar response fields missing from handle_health_pillars"
fi

echo
echo "[test-pillar-dashboard] All checks passed."
