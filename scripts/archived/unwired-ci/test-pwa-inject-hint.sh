#!/usr/bin/env bash
# test-pwa-inject-hint.sh — PRODUCT-116
#
# Source-level assertions that the strategic-redirect composer is wired:
# frontend <chump-hint-composer> component, TTL presets, POST /api/inject-hint,
# history list from /api/ambient/recent?kind=operator_hint, and server-side
# ambient emission of kind=operator_hint.
#
# No binary build required — checks app.js and web_server.rs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== PRODUCT-116 strategic-redirect composer — source assertions ==="
echo

# ── AC: Composer component bound to /api/inject-hint ─────────────────────────
echo "--- AC-1: Composer component wired to /api/inject-hint ---"

grep -q 'chump-hint-composer' "$APP_JS" \
  && ok "chump-hint-composer custom element defined" \
  || fail "chump-hint-composer NOT found"

grep -q '/api/inject-hint' "$APP_JS" \
  && ok "/api/inject-hint fetch call in composer" \
  || fail "/api/inject-hint NOT called from composer"

grep -q 'ChumpHintComposer' "$APP_JS" \
  && ok "ChumpHintComposer class defined" \
  || fail "ChumpHintComposer class NOT found"

# ── AC: TTL default 60 min, presets ──────────────────────────────────────────
echo "--- AC-2: TTL preset selector ---"

grep -q 'ttl_minutes\|ttl-btn\|selectedTtl\|#selectedTtl' "$APP_JS" \
  && ok "TTL minutes wired in composer" \
  || fail "TTL minutes NOT found"

grep -q '"15"\|data-minutes="15"' "$APP_JS" \
  && ok "15-min TTL preset present" \
  || fail "15-min TTL preset NOT found"

grep -q '"240"\|data-minutes="240"' "$APP_JS" \
  && ok "4-hr (240 min) TTL preset present" \
  || fail "4-hr TTL preset NOT found"

grep -q '"1440"\|data-minutes="1440"' "$APP_JS" \
  && ok "24-hr (1440 min) TTL preset present" \
  || fail "24-hr TTL preset NOT found"

grep -q 'hint-ttl-selected' "$APP_JS" \
  && ok "default TTL selected state wired" \
  || fail "TTL selected state NOT found"

# ── AC: History list below composer ──────────────────────────────────────────
echo "--- AC-3: Recent hint history list ---"

grep -q 'ambient/recent.*operator_hint\|operator_hint.*ambient/recent\|kind=operator_hint' "$APP_JS" \
  && ok "/api/ambient/recent?kind=operator_hint called for history" \
  || fail "/api/ambient/recent?kind=operator_hint NOT called"

grep -q 'hint-history-list\|hint-history' "$APP_JS" \
  && ok "hint-history-list element present" \
  || fail "hint-history-list NOT found"

grep -q '#ttlLabel\|ttlLabel\|ttl.*left\|min left' "$APP_JS" \
  && ok "TTL countdown shown on history items" \
  || fail "TTL countdown NOT found in history"

# ── AC: Server-side ambient emit ──────────────────────────────────────────────
echo "--- AC: Server emits kind=operator_hint to ambient.jsonl ---"

grep -q '"operator_hint"' "$WEB_SERVER" \
  && ok "operator_hint kind emitted in web_server.rs" \
  || fail "operator_hint kind NOT found in web_server.rs"

grep -q 'ttl_minutes' "$WEB_SERVER" \
  && ok "ttl_minutes field accepted by InjectHintRequest" \
  || fail "ttl_minutes NOT in InjectHintRequest"

grep -q 'ambient.jsonl' "$WEB_SERVER" \
  && ok "ambient.jsonl write path found in server" \
  || fail "ambient.jsonl write NOT found in server"

# ── AC: Embedded in gap queue view ───────────────────────────────────────────
echo "--- AC: Composer embedded in fleet agent view ---"

# The <chump-hint-composer> tag must appear near the ChumpViewAgent class.
# Strategy: extract text between 'class ChumpViewAgent' and 'customElements.define.*ChumpViewAgent'
# and check it contains the tag.
_agent_block=$(awk '/class ChumpViewAgent/,/customElements\.define.*chump-view-agent/' "$APP_JS")
if echo "$_agent_block" | grep -q 'chump-hint-composer'; then
  ok "<chump-hint-composer> embedded in ChumpViewAgent template"
else
  fail "<chump-hint-composer> NOT embedded in ChumpViewAgent"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
