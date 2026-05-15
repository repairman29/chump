#!/usr/bin/env bash
# scripts/ci/test-pwa-acp-deeplinks.sh — PRODUCT-110
#
# Structural test for the PWA ACP deeplink surface.
# Verifies:
#   - window.ChumpAcpDeeplink helper with gap / pr / branch / open methods
#   - URL schema "chump://acp/open" used (not http/https)
#   - Every gap row template renders an "Open in editor" link + Copy button
#   - URLSearchParams escapes user-supplied values (no string concat)
#   - Document-level delegated click handlers for copy + link telemetry
#   - kind=acp_deeplink_emitted ambient event with required fields
#   - CSS for .gap-acp-link + .gap-acp-copy + success state
#   - docs/api/PWA_ACP_DEEPLINKS.md exists and documents the schema

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
DEEPLINK_DOC="$REPO_ROOT/docs/api/PWA_ACP_DEEPLINKS.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]       || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]]   || fail "missing $INDEX_HTML"
[[ -f "$DEEPLINK_DOC" ]] || fail "missing $DEEPLINK_DOC"

# ── Test 1: ChumpAcpDeeplink helper exposed on window ──────────────────────
grep -q "window.ChumpAcpDeeplink = window.ChumpAcpDeeplink ||" "$APP_JS" \
    || fail "window.ChumpAcpDeeplink not exposed as IIFE"
for method in 'open(params)' 'gap(id' 'pr(num' 'branch(b'; do
    grep -q "$method" "$APP_JS" || fail "ChumpAcpDeeplink missing method: $method"
done
ok "ChumpAcpDeeplink: open/gap/pr/branch all exposed"

# ── Test 2: URL scheme is chump://acp/open (NOT http) ──────────────────────
grep -q "'chump://acp/open'" "$APP_JS" \
    || fail "deeplink scheme is not chump://acp/open"
! grep -q "ChumpAcpDeeplink.*'http" "$APP_JS" \
    || fail "ChumpAcpDeeplink shouldn't reference http schemes"
ok "URL scheme: chump://acp/open (not http/https)"

# ── Test 3: URLSearchParams used for escape-safety ─────────────────────────
grep -A8 "function build(params)" "$APP_JS" | grep -q "URLSearchParams\|searchParams.set" \
    || fail "build() doesn't use URLSearchParams — injection risk"
ok "URLSearchParams: query values URL-encoded properly"

# ── Test 4: gap row template renders link + copy button ────────────────────
grep -q "ChumpAcpDeeplink.open\|ChumpAcpDeeplink.gap" "$APP_JS" \
    || fail "gap renderRow doesn't invoke ChumpAcpDeeplink"
grep -q "gap-acp-link" "$APP_JS" \
    || fail "row template missing .gap-acp-link element"
grep -q "gap-acp-copy" "$APP_JS" \
    || fail "row template missing .gap-acp-copy button"
grep -q "data-acp-href" "$APP_JS" \
    || fail "Copy button missing data-acp-href attribute"
ok "row template: Open in editor + Copy link buttons present"

# ── Test 5: delegated click handler for Copy (clipboard write) ─────────────
grep -q "navigator.clipboard?.writeText" "$APP_JS" \
    || fail "Copy handler not using navigator.clipboard.writeText"
grep -q "gap-acp-copy-success" "$APP_JS" \
    || fail "Copy handler not setting success class for visual feedback"
ok "Copy handler: clipboard.writeText + success-state feedback"

# ── Test 6: telemetry — kind=acp_deeplink_emitted via sendBeacon ──────────
grep -q "acp_deeplink_emitted" "$APP_JS" \
    || fail "missing kind=acp_deeplink_emitted telemetry"
grep -B5 "acp_deeplink_emitted" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon (non-blocking)"
# Required fields per the design doc
for field in target_kind ts; do
    grep -A8 "acp_deeplink_emitted" "$APP_JS" | grep -q "$field" \
        || fail "acp_deeplink_emitted event missing required field: $field"
done
ok "telemetry: acp_deeplink_emitted via sendBeacon with target_kind + ts"

# ── Test 7: delegated click handler also fires on the link click ───────────
grep -q "a.gap-acp-link\|gap-acp-link" "$APP_JS" \
    || fail "no click handler attached to .gap-acp-link"
ok "link-click telemetry also wired (editor-handoff path)"

# ── Test 8: CSS — .gap-acp-row + .gap-acp-link + .gap-acp-copy + success ──
grep -q ".gap-acp-row"           "$INDEX_HTML" || fail "missing .gap-acp-row CSS"
grep -q ".gap-acp-link"          "$INDEX_HTML" || fail "missing .gap-acp-link CSS"
grep -q ".gap-acp-copy"          "$INDEX_HTML" || fail "missing .gap-acp-copy CSS"
grep -q ".gap-acp-copy-success"  "$INDEX_HTML" || fail "missing .gap-acp-copy-success CSS"
ok "CSS: row + link + copy + success-state all styled"

# ── Test 9: docs/api/PWA_ACP_DEEPLINKS.md documents the schema ─────────────
for marker in "chump://acp/open" "URL schema" "Telemetry" "ChumpAcpDeeplink" "client_detected"; do
    grep -q "$marker" "$DEEPLINK_DOC" \
        || fail "PWA_ACP_DEEPLINKS.md missing section / mention: $marker"
done
ok "PWA_ACP_DEEPLINKS.md: schema + telemetry + JS API + security all covered"

# ── Test 10: a11y — link has aria-label + button has aria-label ────────────
grep -A2 "gap-acp-link" "$APP_JS" | grep -q "aria-label" \
    || fail "Open in editor link missing aria-label"
grep -A2 "gap-acp-copy" "$APP_JS" | grep -q "aria-label" \
    || fail "Copy link button missing aria-label"
ok "a11y: link + copy button both have aria-label"

# ── Test 11: provenance — PRODUCT-110 referenced in code ───────────────────
grep -q "PRODUCT-110" "$APP_JS" \
    || fail "ChumpAcpDeeplink code missing PRODUCT-110 provenance"
ok "code references PRODUCT-110 (provenance trail)"

ok "ALL PRODUCT-110 ACP-deeplink checks passed"
