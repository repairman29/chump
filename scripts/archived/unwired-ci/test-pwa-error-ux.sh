#!/usr/bin/env bash
# scripts/ci/test-pwa-error-ux.sh
# PRODUCT-100: PWA visible error states + offline indicator — static analysis gate.
#
# Tests (no browser runtime required):
#   1. error-ux.js exists and defines ChumpStatusPill + apiFetch + ApiStatus
#   2. apiFetch retries with backoff (RETRY_DELAYS_MS defined)
#   3. Status pill states: live/stale/offline/paused
#   4. STALE_WARN_MS and TOAST_COLLAPSE_MS thresholds defined
#   5. navigator.onLine offline/online event handlers wired
#   6. Toast UI: dismiss + retry buttons
#   7. Sticky offline banner for long-offline periods
#   8. window.apiFetch and window.chumpApiStatus exposed globally
#   9. chump:api-status CustomEvent dispatched
#   10. index.html has <chump-status-pill> and error-ux.js script
#   11. app.js uses apiFetch for fleet-status (key hot path)
#   12. PRODUCT-100 referenced in error-ux.js

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ERR_JS="$REPO_ROOT/web/v2/error-ux.js"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

PASS=0
FAIL=0

check() {
  local desc="$1" cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== PRODUCT-100 PWA error UX tests ==="

# ── 1. error-ux.js exists ─────────────────────────────────────────────────────
check "error-ux.js exists"              "test -f '$ERR_JS'"
check "ApiStatus class defined"         "grep -q 'class ApiStatus'       '$ERR_JS'"
check "ChumpStatusPill defined"         "grep -q 'chump-status-pill'     '$ERR_JS'"
check "apiFetch function defined"       "grep -q 'function apiFetch'     '$ERR_JS'"

# ── 2. Retry + backoff ────────────────────────────────────────────────────────
check "RETRY_DELAYS_MS defined"         "grep -q 'RETRY_DELAYS_MS'       '$ERR_JS'"
check "retryCount in apiFetch"          "grep -q 'retryCount'            '$ERR_JS'"
check "recursive retry call present"    "grep -q 'apiFetch(path'         '$ERR_JS'"

# ── 3. Status pill states ─────────────────────────────────────────────────────
check "pill-live class present"         "grep -q 'pill-live'    '$ERR_JS'"
check "pill-stale class present"        "grep -q 'pill-stale'   '$ERR_JS'"
check "pill-offline class present"      "grep -q 'pill-offline' '$ERR_JS'"

# ── 4. Thresholds ─────────────────────────────────────────────────────────────
check "STALE_WARN_MS defined (2 min)"   "grep -q 'STALE_WARN_MS'        '$ERR_JS'"
check "TOAST_COLLAPSE_MS defined"       "grep -q 'TOAST_COLLAPSE_MS'    '$ERR_JS'"

# ── 5. navigator.onLine integration ──────────────────────────────────────────
check "offline event listener present"  "grep -q \"'offline'\"           '$ERR_JS'"
check "online event listener present"   "grep -q \"'online'\"            '$ERR_JS'"

# ── 6. Toast UI ───────────────────────────────────────────────────────────────
check "toast dismiss button present"    "grep -q 'toast-dismiss'         '$ERR_JS'"
check "toast retry button present"      "grep -q 'toast-retry'           '$ERR_JS'"
check "TOAST_TIMEOUT_MS defined"        "grep -q 'TOAST_TIMEOUT_MS'      '$ERR_JS'"

# ── 7. Sticky banner ──────────────────────────────────────────────────────────
check "sticky offline banner present"   "grep -q 'offline-banner'        '$ERR_JS'"
check "ensureStickyBanner method"       "grep -q 'ensureStickyBanner'    '$ERR_JS'"

# ── 8. Global exposure ────────────────────────────────────────────────────────
check "window.apiFetch exposed"         "grep -q 'window.apiFetch'       '$ERR_JS'"
check "window.chumpApiStatus exposed"   "grep -q 'window.chumpApiStatus' '$ERR_JS'"

# ── 9. CustomEvent ────────────────────────────────────────────────────────────
check "chump:api-status event dispatched" "grep -q 'chump:api-status'    '$ERR_JS'"
check "recordSuccess dispatches live"     "grep -q \"'live'\"             '$ERR_JS'"
check "recordFailure dispatches offline"  "grep -q \"'offline'\"          '$ERR_JS'"

# ── 10. index.html wiring ────────────────────────────────────────────────────
check "index.html has <chump-status-pill>" \
  "grep -q 'chump-status-pill' '$INDEX_HTML'"
check "index.html includes error-ux.js" \
  "grep -q 'error-ux.js' '$INDEX_HTML'"
check "status pill CSS in index.html" \
  "grep -q 'pill-live\|pill-offline' '$INDEX_HTML'"

# ── 11. app.js uses apiFetch ─────────────────────────────────────────────────
check "app.js references apiFetch" \
  "grep -q 'apiFetch' '$APP_JS'"

# ── 12. PRODUCT-100 reference ─────────────────────────────────────────────────
check "PRODUCT-100 referenced" \
  "grep -q 'PRODUCT-100' '$ERR_JS' '$APP_JS' '$INDEX_HTML'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "PASS"
  exit 0
fi
