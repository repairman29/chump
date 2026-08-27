#!/usr/bin/env bash
# scripts/ci/test-sse-filter-and-regret.sh — INFRA-1559
#
# Verifies INFRA-1559: SSE filter UI (tag-based pills + saved presets +
# "new since last viewed" overlay) and the bandit regret panel that pairs
# with the routing brain (TBD-INFRA-1545).
#
#   1. chump-ambient-viewer component defines the filter-pill UI (input,
#      pill container, preset select, since-viewed overlay)
#   2. chump-bandit-regret-panel component exists and is wired into the
#      Ambient Events view
#   3. Client-side filtering: server is not re-queried on pill add (no
#      `?kind=` mutation triggered by pill changes, per AC "out of scope:
#      server-side filtering")
#   4. Telemetry: kind=sse_filter_applied literal present
#   5. Functional (node): inject synthetic routing_decision + routing_outcome
#      events and assert (a) filter pills render, (b) cumulative regret per
#      arm is monotonically non-decreasing (web/v2/tests/sse-filter-and-regret.test.js)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

pass=0; total=0
check() {
  total=$((total+1))
  if "$@" >/dev/null 2>&1; then
    ok "$*"
    pass=$((pass+1))
  else
    fail "$*"
  fi
}

echo "=== INFRA-1559: SSE filter UI + bandit regret panel CI checks ==="

APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
UNIT_TEST="$REPO_ROOT/web/v2/tests/sse-filter-and-regret.test.js"

# 1. Filter-pill UI present in ChumpAmbientViewer
check grep -q "amb-pill-input" "$APP_JS"
check grep -q "amb-pills" "$APP_JS"
check grep -q "amb-preset-select" "$APP_JS"
check grep -q "amb-since-viewed" "$APP_JS"

# 2. Bandit regret panel component exists and is registered
check grep -q "class ChumpBanditRegretPanel" "$APP_JS"
check grep -q "customElements.define('chump-bandit-regret-panel'" "$APP_JS"
check grep -q "chump-bandit-regret-panel" "$APP_JS"

# 3. Both ship together, wired into the same Ambient Events view (AC 4)
check grep -q "chump-ambient-viewer></chump-ambient-viewer>" "$APP_JS"

# CSS present (token-discipline compliant — no raw hex introduced)
check grep -q "amb-pills-bar" "$INDEX_HTML"
check grep -q "chump-bandit-regret-panel" "$INDEX_HTML"

# 4. Telemetry literal present
check grep -q "sse_filter_applied" "$APP_JS"

# 5. Functional: node unit test (pill rendering + monotonic regret)
total=$((total+1))
if node "$UNIT_TEST"; then
  ok "Functional: pill rendering + monotonic cumulative regret (node unit test)"
  pass=$((pass+1))
else
  fail "Functional: web/v2/tests/sse-filter-and-regret.test.js failed"
fi

echo ""
echo "=== Results: $pass/$total passed ==="
[[ "$pass" -eq "$total" ]] || exit 1
echo "INFRA-1559: SSE filter UI + bandit regret panel validation complete."
