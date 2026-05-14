#!/usr/bin/env bash
# test-pwa-gap-search.sh — PRODUCT-089
#
# Source-level assertions that /api/gaps/search handler and search UI are wired.
# No binary build required — checks src/web_server.rs and web/v2/app.js.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"
APP_JS="$REPO_ROOT/web/v2/app.js"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== PRODUCT-089 /api/gaps/search source assertions ==="
echo

# ── Backend ──────────────────────────────────────────────────────────────────
echo "--- Backend: src/web_server.rs ---"

grep -q '/api/gaps/search' "$WEB_SERVER" \
  && ok "/api/gaps/search route registered" \
  || fail "/api/gaps/search route NOT registered"

grep -q 'handle_gaps_search' "$WEB_SERVER" \
  && ok "handle_gaps_search handler present" \
  || fail "handle_gaps_search handler NOT found"

grep -q 'GapSearchQuery' "$WEB_SERVER" \
  && ok "GapSearchQuery params struct present" \
  || fail "GapSearchQuery NOT found"

grep -q 'has_ac' "$WEB_SERVER" \
  && ok "has_ac filter param present" \
  || fail "has_ac filter NOT found"

grep -q 'PRODUCT-089' "$WEB_SERVER" \
  && ok "PRODUCT-089 referenced in web_server.rs" \
  || fail "PRODUCT-089 NOT referenced"

# ── Frontend ──────────────────────────────────────────────────────────────────
echo "--- Frontend: web/v2/app.js ---"

grep -q '/api/gaps/search' "$APP_JS" \
  && ok "/api/gaps/search fetch call present" \
  || fail "/api/gaps/search NOT called from app.js"

grep -q 'gap-search-input' "$APP_JS" \
  && ok "gap-search-input element present" \
  || fail "gap-search-input NOT found"

grep -q 'debounce\|setTimeout' "$APP_JS" \
  && ok "debounce (setTimeout) wired to search" \
  || fail "debounce NOT found in search path"

grep -q 'gap-filter-status\|gap-filter-priority' "$APP_JS" \
  && ok "filter dropdowns present" \
  || fail "filter dropdowns NOT found"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
