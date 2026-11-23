#!/usr/bin/env bash
# scripts/ci/test-product-094-notifications.sh
# PRODUCT-094: PWA in-app notification center static analysis test.
#
# Tests (no browser runtime required):
#   1. notification-center.js exists and defines the required custom elements
#   2. NOTIF_KINDS covers the four required event kinds
#   3. localStorage persistence key is present
#   4. mark-all-read and dismiss functions exist
#   5. ChumpNav includes a 'notifications' nav item with badge:true
#   6. VIEWS map registers 'notifications' → chump-view-notifications
#   7. index.html includes <chump-notification-center> and notification-center.js
#   8. web_server.rs references PRODUCT-094
#
# Exit 0 = all pass, non-zero = failure(s).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NC_JS="$REPO_ROOT/web/v2/notification-center.js"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

PASS=0
FAIL=0

check() {
  local desc="$1"; local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== PRODUCT-094 notification center tests ==="

# ── 1. File exists ─────────────────────────────────────────────────────────────
check "notification-center.js exists" "test -f '$NC_JS'"

# ── 2. Custom elements defined ─────────────────────────────────────────────────
check "ChumpNotificationCenter defined" "grep -q 'chump-notification-center' '$NC_JS'"
check "ChumpViewNotifications defined"  "grep -q 'chump-view-notifications'  '$NC_JS'"
check "ChumpNotifStore class exists"    "grep -q 'class ChumpNotifStore'     '$NC_JS'"

# ── 3. Required NOTIF_KINDS covered ───────────────────────────────────────────
check "fleet_wedge in NOTIF_KINDS"    "grep -q 'fleet_wedge'    '$NC_JS'"
check "pr_stuck in NOTIF_KINDS"       "grep -q 'pr_stuck'       '$NC_JS'"
check "needs_judgment in NOTIF_KINDS" "grep -q 'needs_judgment' '$NC_JS'"
check "gap_shipped in NOTIF_KINDS"    "grep -q 'gap_shipped'    '$NC_JS'"

# ── 4. Color mapping for all required kinds ────────────────────────────────────
check "fleet_wedge → red"    "grep -A2 'fleet_wedge' '$NC_JS' | grep -q 'red'"
check "pr_stuck → yellow"    "grep -A2 'pr_stuck'    '$NC_JS' | grep -q 'yellow'"
check "gap_shipped → green"  "grep -A2 'gap_shipped' '$NC_JS' | grep -q 'green'"
check "needs_judgment → orange" "grep -A2 'needs_judgment' '$NC_JS' | grep -q 'orange'"

# ── 5. Persistence ────────────────────────────────────────────────────────────
check "localStorage STORAGE_KEY defined"   "grep -q 'chump-notifications-v' '$NC_JS'"
check "localStorage.setItem present"       "grep -q 'localStorage.setItem'   '$NC_JS'"
check "localStorage.getItem present"       "grep -q 'localStorage.getItem'   '$NC_JS'"

# ── 6. Mark-all-read + dismiss ────────────────────────────────────────────────
check "markAllRead function present" "grep -q 'markAllRead' '$NC_JS'"
check "dismiss function present"     "grep -q 'dismiss('    '$NC_JS'"
check "markRead function present"    "grep -q 'markRead('   '$NC_JS'"

# ── 7. SSE connection to /api/ambient/stream ──────────────────────────────────
check "SSE to /api/ambient/stream" "grep -q '/api/ambient/stream' '$NC_JS'"

# ── 8. Global singleton exposed ───────────────────────────────────────────────
check "window.chumpNotifStore exposed" "grep -q 'window.chumpNotifStore' '$NC_JS'"

# ── 9. app.js: notifications nav item + badge ─────────────────────────────────
check "app.js has notifications nav item" "grep -q \"id: 'notifications'\" '$APP_JS'"
check "app.js has badge: true flag"       "grep -q 'badge: true'           '$APP_JS'"
check "app.js VIEWS has notifications"    "grep -q \"notifications:\" '$APP_JS'"
check "app.js notif-nav-badge id"         "grep -q 'notif-nav-badge'       '$APP_JS'"

# ── 10. index.html wiring ─────────────────────────────────────────────────────
check "index.html has <chump-notification-center>" \
  "grep -q 'chump-notification-center' '$INDEX_HTML'"
check "index.html includes notification-center.js" \
  "grep -q 'notification-center.js'    '$INDEX_HTML'"
check "index.html has notif-badge CSS"    \
  "grep -q 'notif-badge'               '$INDEX_HTML'"

# ── 11. web_server.rs PRODUCT-094 reference ───────────────────────────────────
check "web_server.rs references PRODUCT-094" "grep -q 'PRODUCT-094' '$WEB_SERVER'"

# ── 12. Deduplication guard ───────────────────────────────────────────────────
check "60s dedup window present" "grep -q '60_000\|60000' '$NC_JS'"

# ── 13. MAX_STORED cap at 50 ─────────────────────────────────────────────────
check "MAX_STORED = 50" "grep -q 'MAX_STORED.*50\|50.*MAX_STORED' '$NC_JS'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "PASS"
  exit 0
fi
