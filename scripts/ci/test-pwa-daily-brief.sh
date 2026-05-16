#!/usr/bin/env bash
# test-pwa-daily-brief.sh — PRODUCT-078
#
# Verifies the PWA Daily Brief feature:
#   1. Backend: /api/brief route registered in web_server.rs
#   2. Backend: handle_brief handler present and async
#   3. Backend: since query param handled (default 8h)
#   4. Backend: 3 buckets returned (done, needs_judgment, alerts)
#   5. Backend: tracing::debug! observability hook present
#   6. Frontend: daily-brief.js exists + customElements.define present
#   7. Frontend: ChumpViewBrief class present
#   8. Frontend: LAST_VISIT_KEY localStorage key present
#   9. Frontend: dismiss logic present
#  10. Frontend: visibilitychange listener for tab-focus refresh
#  11. index.html: daily-brief.js script tag present
#  12. app.js: brief wired in VIEWS

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "==> PRODUCT-078: PWA Daily Brief tests"

# ── 1. Backend route ──────────────────────────────────────────────────────────

grep -q '"/api/brief"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/brief route registered" || fail "/api/brief route missing"

grep -q 'get(handle_brief)' "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_brief handler wired" || fail "handle_brief not wired"

# ── 2. Handler presence ───────────────────────────────────────────────────────

grep -q 'async fn handle_brief' "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_brief function present" || fail "handle_brief function missing"

# ── 3. since param + default ─────────────────────────────────────────────────

grep -q 'since\|8.*3600\|28800' "$REPO_ROOT/src/web_server.rs" \
    && ok "since param / 8h default present" || fail "since param missing"

# ── 4. Three buckets in response ─────────────────────────────────────────────

# grep directly for each bucket key — simpler than regex-extracting the function body
for bucket in done needs_judgment alerts; do
    grep -q "\"$bucket\"" "$REPO_ROOT/src/web_server.rs" \
        && ok "bucket '$bucket' present in web_server.rs" \
        || fail "bucket '$bucket' missing from web_server.rs"
done

# ── 5. Observability: tracing::debug! ────────────────────────────────────────

grep -q "tracing::debug!\|tracing::info!" "$REPO_ROOT/src/web_server.rs" \
    && ok "tracing hook present in web_server.rs" || fail "tracing hook missing"

# ── 6. Frontend component ─────────────────────────────────────────────────────

[[ -f "$REPO_ROOT/web/v2/daily-brief.js" ]] \
    && ok "daily-brief.js exists" || fail "daily-brief.js missing"

grep -q "customElements.define.*chump-view-brief" "$REPO_ROOT/web/v2/daily-brief.js" \
    && ok "customElements.define present" || fail "customElements.define missing"

# ── 7. ChumpViewBrief class ───────────────────────────────────────────────────

grep -q "class ChumpViewBrief" "$REPO_ROOT/web/v2/daily-brief.js" \
    && ok "ChumpViewBrief class present" || fail "ChumpViewBrief class missing"

# ── 8. localStorage last-visit key ───────────────────────────────────────────

grep -q "LAST_VISIT_KEY\|chump:last-pwa-visit" "$REPO_ROOT/web/v2/daily-brief.js" \
    && ok "LAST_VISIT_KEY present" || fail "LAST_VISIT_KEY missing"

# ── 9. Dismiss logic ─────────────────────────────────────────────────────────

grep -q "dismiss\|DISMISS_KEY" "$REPO_ROOT/web/v2/daily-brief.js" \
    && ok "Dismiss logic present" || fail "Dismiss logic missing"

# ── 10. visibilitychange listener ────────────────────────────────────────────

grep -q "visibilitychange" "$REPO_ROOT/web/v2/daily-brief.js" \
    && ok "visibilitychange listener present" || fail "visibilitychange missing"

# ── 11. index.html ───────────────────────────────────────────────────────────

grep -q "daily-brief.js" "$REPO_ROOT/web/v2/index.html" \
    && ok "daily-brief.js in index.html" || fail "daily-brief.js not in index.html"

# ── 12. app.js VIEWS ────────────────────────────────────────────────────────

grep -q "brief.*chump-view-brief" "$REPO_ROOT/web/v2/app.js" \
    && ok "brief view wired in VIEWS" || fail "brief view not in VIEWS"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL CHECKS PASSED — PRODUCT-078 verified" && exit 0 || exit 1
