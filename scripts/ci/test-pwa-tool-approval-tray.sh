#!/usr/bin/env bash
# scripts/ci/test-pwa-tool-approval-tray.sh — PRODUCT-109
#
# Structural test for the <chump-tool-approval-tray> Web Component.
# Verifies the wiring contract:
#   - Component defined + mounted in index.html
#   - Listens for document-level CustomEvent chump:tool_approval
#   - Chat SSE re-broadcaster dispatches that event on tool_approval_request
#   - Approve/Deny POSTs to /api/approve with the canonical body shape
#   - Multi-tab dedup via BroadcastChannel('chump-tool-approval')
#   - Expired-deny-by-default tick handler
#   - Batch operations (approve-all / deny-all)
#   - A11y (role=log + role=listitem + aria-keyshortcuts a/d)
#   - Telemetry: kind=tool_approval_tray_action via sendBeacon
#   - CSS for tray shell + risk-level color classes + mobile collapse
#
# End-to-end SSE-to-decision flow is exercised by the e2e-pwa CI job; this
# structural test catches wiring regressions cheaply.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
CHAT_JS="$REPO_ROOT/web/v2/chat.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$CHAT_JS" ]]    || fail "missing $CHAT_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

# ── Test 1: ChumpToolApprovalTray class + customElements.define ─────────────
grep -q "class ChumpToolApprovalTray" "$APP_JS" \
    || fail "app.js missing ChumpToolApprovalTray class"
grep -q "customElements.define('chump-tool-approval-tray'" "$APP_JS" \
    || fail "app.js missing customElements.define for chump-tool-approval-tray"
ok "ChumpToolApprovalTray class defined + registered"

# ── Test 2: mounted in index.html app shell ─────────────────────────────────
grep -q "<chump-tool-approval-tray>" "$INDEX_HTML" \
    || fail "index.html doesn't mount <chump-tool-approval-tray>"
ok "tray mounted in app shell"

# ── Test 3: listens for chump:tool_approval document event ─────────────────
grep -q "addEventListener('chump:tool_approval'" "$APP_JS" \
    || fail "tray not listening for document chump:tool_approval event"
ok "tray listens for chump:tool_approval CustomEvent"

# ── Test 4: chat.js dispatches chump:tool_approval on SSE event ────────────
grep -q "tool_approval_request" "$CHAT_JS" \
    || fail "chat.js missing tool_approval_request SSE handler"
grep -q "chump:tool_approval" "$CHAT_JS" \
    || fail "chat.js doesn't dispatch chump:tool_approval CustomEvent"
ok "chat.js re-broadcasts tool_approval_request SSE → chump:tool_approval"

# ── Test 5: POST /api/approve with canonical body shape ────────────────────
grep -q "fetch('/api/approve'" "$APP_JS" \
    || fail "tray's decide() must POST to /api/approve"
grep -A3 "fetch('/api/approve'" "$APP_JS" | grep -q "request_id" \
    || fail "/api/approve body missing request_id"
grep -A3 "fetch('/api/approve'" "$APP_JS" | grep -q "allowed" \
    || fail "/api/approve body missing allowed boolean"
ok "tray decisions POST /api/approve {request_id, allowed}"

# ── Test 6: multi-tab dedup via BroadcastChannel ───────────────────────────
grep -q "BroadcastChannel('chump-tool-approval'" "$APP_JS" \
    || fail "tray missing BroadcastChannel('chump-tool-approval') for multi-tab dedup"
grep -q "channel.*addEventListener\|channel?.addEventListener\|#channel\.addEventListener\|this.#channel" "$APP_JS" \
    || fail "tray BroadcastChannel handler not wired"
ok "multi-tab dedup: BroadcastChannel('chump-tool-approval') wired"

# ── Test 7: expired-deny-by-default tick ───────────────────────────────────
grep -q "expires_at_secs\|fmtCountdown\|#tick" "$APP_JS" \
    || fail "tray missing expires_at_secs handling / countdown / tick"
grep -A30 "#tick" "$APP_JS" | grep -q "auto-denied\|expired\|allowed: false" \
    || fail "tray's tick should auto-deny expired requests"
ok "expired-deny-by-default: tick auto-POSTs allowed=false on expiry"

# ── Test 8: batch approve-all / deny-all ────────────────────────────────────
grep -q "tat-approve-all\|tat-deny-all" "$APP_JS" \
    || fail "tray missing batch approve-all / deny-all buttons"
grep -q "#decideAll" "$APP_JS" \
    || fail "tray missing #decideAll method"
ok "batch ops: approve-all + deny-all wired"

# ── Test 9: a11y — role=log + role=listitem + aria-keyshortcuts a/d ────────
grep -q "role=\"log\"" "$APP_JS" || fail "tray shell missing role=log"
grep -q "aria-live=\"polite\"" "$APP_JS" || fail "tray missing aria-live=polite"
grep -q "role=\"listitem\"" "$APP_JS" || fail "tray rows missing role=listitem"
grep -q "aria-keyshortcuts=\"a\"" "$APP_JS" || fail "Approve button missing aria-keyshortcuts=a"
grep -q "aria-keyshortcuts=\"d\"" "$APP_JS" || fail "Deny button missing aria-keyshortcuts=d"
ok "a11y: role=log + role=listitem + aria-keyshortcuts a/d all present"

# ── Test 10: telemetry — kind=tool_approval_tray_action via sendBeacon ─────
grep -q "tool_approval_tray_action" "$APP_JS" \
    || fail "tray missing kind=tool_approval_tray_action telemetry"
grep -B5 "tool_approval_tray_action" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon (non-blocking)"
ok "telemetry: kind=tool_approval_tray_action via sendBeacon"

# ── Test 11: CSS — shell + risk classes + mobile collapse ──────────────────
grep -q "chump-tool-approval-tray .tat-shell" "$INDEX_HTML" \
    || fail "index.html missing .tat-shell CSS"
for risk in low medium high unknown; do
    grep -q "tat-risk-$risk" "$INDEX_HTML" \
        || fail "index.html missing .tat-risk-$risk color class"
done
grep -A50 "chump-tool-approval-tray" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "index.html missing mobile media query for tray"
ok "CSS: shell + 4 risk-level colors + mobile collapse all present"

# ── Test 12: hidden when empty (tat-shell[hidden] suppresses display) ──────
grep -q "tat-shell\[hidden\]\|shell.hidden" "$APP_JS" \
    || fail "tray must hide shell when list is empty"
ok "tray hidden when no pending approvals"

# ── Test 13: design-doc / gap provenance ────────────────────────────────────
grep -q "PRODUCT-109\|OPERATOR_CONSOLE_V2" "$APP_JS" \
    || fail "ChumpToolApprovalTray missing PRODUCT-109 / OPERATOR_CONSOLE_V2 provenance"
ok "code references PRODUCT-109 + design doc (provenance trail)"

ok "ALL PRODUCT-109 tool-approval-tray checks passed"
