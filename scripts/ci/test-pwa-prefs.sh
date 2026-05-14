#!/usr/bin/env bash
# scripts/ci/test-pwa-prefs.sh
# PRODUCT-098: PWA localStorage-backed user prefs — static analysis gate.
#
# Verifies:
#   1. prefs.js exists and exports the ChumpPrefs singleton as window.chumpPrefs
#   2. NAMESPACE = 'chump.prefs.' — all keys namespaced
#   3. get(key, default) and set(key, val) functions present
#   4. Legacy migration: parallelism-limit key is aliased
#   5. pwa_prefs_changed ambient event is emitted on set()
#   6. chump:pref-changed CustomEvent dispatched on set()
#   7. app.js wires parallelism-limit through window.chumpPrefs
#   8. app.js persists last-view on navigate
#   9. app.js restores last-view on boot
#   10. ambient-viewer.js restores kind filter from prefs on load
#   11. ambient-viewer.js persists kind filter on chip click
#   12. index.html loads prefs.js before app.js
#   13. PRODUCT-098 referenced in app.js or prefs.js

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFS_JS="$REPO_ROOT/web/v2/prefs.js"
APP_JS="$REPO_ROOT/web/v2/app.js"
AV_JS="$REPO_ROOT/web/v2/ambient-viewer.js"
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

echo "=== PRODUCT-098 PWA user prefs tests ==="

# ── 1. prefs.js exists ────────────────────────────────────────────────────────
check "prefs.js exists"               "test -f '$PREFS_JS'"
check "ChumpPrefs class defined"      "grep -q 'class ChumpPrefs'    '$PREFS_JS'"
check "window.chumpPrefs exported"    "grep -q 'window.chumpPrefs'   '$PREFS_JS'"

# ── 2. Namespace ──────────────────────────────────────────────────────────────
check "NAMESPACE = chump.prefs."      "grep -q \"chump.prefs.\" '$PREFS_JS'"

# ── 3. Core API ───────────────────────────────────────────────────────────────
check "get() method exists"           "grep -q 'get(key' '$PREFS_JS'"
check "set() method exists"           "grep -q 'set(key' '$PREFS_JS'"
check "remove() method exists"        "grep -q 'remove(' '$PREFS_JS'"

# ── 4. Legacy migration ───────────────────────────────────────────────────────
check "parallelism-limit migration"   "grep -q 'parallelism-limit' '$PREFS_JS'"
check "LEGACY_MIGRATION map defined"  "grep -q 'LEGACY_MIGRATION'  '$PREFS_JS'"

# ── 5. Ambient telemetry ──────────────────────────────────────────────────────
check "pwa_prefs_changed kind emitted"  "grep -q 'pwa_prefs_changed' '$PREFS_JS'"
check "fetch /api/ambient/emit present" "grep -q '/api/ambient/emit' '$PREFS_JS'"

# ── 6. CustomEvent dispatch ───────────────────────────────────────────────────
check "chump:pref-changed event dispatched" "grep -q 'chump:pref-changed' '$PREFS_JS'"

# ── 7. app.js parallelism via chumpPrefs ──────────────────────────────────────
check "app.js uses chumpPrefs for parallelism" \
  "grep -q 'chumpPrefs.*parallelism\|parallelism.*chumpPrefs' '$APP_JS'"

# ── 8. app.js persists last-view on navigate ─────────────────────────────────
check "app.js persists last-view on navigate" \
  "grep -A8 'chump:navigate' '$APP_JS' | grep -q 'last-view'"

# ── 9. app.js restores last-view on boot ─────────────────────────────────────
check "app.js restores last-view from prefs" \
  "grep -q 'last-view' '$APP_JS'"

# ── 10. ambient-viewer.js restores kind filter ────────────────────────────────
check "ambient-viewer.js reads ambient-kind-filter from prefs" \
  "grep -q 'ambient-kind-filter' '$AV_JS'"
check "ambient-viewer.js uses chumpPrefs on load" \
  "grep -q 'chumpPrefs.*get\|get.*ambient-kind' '$AV_JS'"

# ── 11. ambient-viewer.js persists kind filter ────────────────────────────────
check "ambient-viewer.js sets ambient-kind-filter pref" \
  "grep -q \"chumpPrefs.*set.*ambient-kind\|set.*'ambient-kind-filter'\" '$AV_JS'"

# ── 12. index.html loads prefs.js ────────────────────────────────────────────
check "index.html includes prefs.js" \
  "grep -q 'prefs.js' '$INDEX_HTML'"
check "prefs.js appears before app.js in index.html" \
  "python3 -c \"
import sys
html = open('$INDEX_HTML').read()
pi = html.find('prefs.js')
ai = html.find('app.js')
sys.exit(0 if pi < ai and pi >= 0 else 1)
\""

# ── 13. PRODUCT-098 referenced ────────────────────────────────────────────────
check "PRODUCT-098 referenced in prefs.js or app.js" \
  "grep -q 'PRODUCT-098' '$PREFS_JS' '$APP_JS' '$AV_JS' '$INDEX_HTML'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "PASS"
  exit 0
fi
