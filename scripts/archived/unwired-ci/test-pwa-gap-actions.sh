#!/usr/bin/env bash
# test-pwa-gap-actions.sh — PRODUCT-114
#
# Source-level assertions that gap row action buttons (Claim / Dispatch / Retry)
# are wired in web/v2/app.js with correct API endpoints, CSRF headers,
# in-flight disabled state, and confirmation dialog.
#
# No binary build required — checks app.js for structural presence.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== PRODUCT-114 gap row action buttons — source assertions ==="
echo

# ── AC-1: Claim button ────────────────────────────────────────────────────────
echo "--- AC-1: Claim button ---"

grep -q 'gap-claim-btn' "$APP_JS" \
  && ok "gap-claim-btn CSS class present in renderRow" \
  || fail "gap-claim-btn NOT found in renderRow"

grep -q '/api/gap/claim/' "$APP_JS" \
  && ok "/api/gap/claim/{id} fetch call present" \
  || fail "/api/gap/claim/{id} NOT called"

grep -q '#updateRowStatus\|updateRowStatus' "$APP_JS" \
  && ok "row status updated inline after claim" \
  || fail "inline row status update NOT found"

# ── AC-2: Dispatch button ─────────────────────────────────────────────────────
echo "--- AC-2: Dispatch button ---"

grep -q 'gap-work-btn' "$APP_JS" \
  && ok "gap-work-btn (Dispatch) CSS class present" \
  || fail "gap-work-btn NOT found"

grep -q '/api/gap/work/' "$APP_JS" \
  && ok "/api/gap/work/{id} fetch call present" \
  || fail "/api/gap/work/{id} NOT called"

grep -q 'confirm(' "$APP_JS" \
  && ok "confirmation dialog present before Dispatch" \
  || fail "confirmation dialog NOT found"

# ── AC-3: Retry button ────────────────────────────────────────────────────────
echo "--- AC-3: Retry button ---"

grep -q 'gap-retry-btn' "$APP_JS" \
  && ok "gap-retry-btn CSS class present in renderRow" \
  || fail "gap-retry-btn NOT found in renderRow"

grep -q '/retry' "$APP_JS" \
  && ok "/api/gap/work/{id}/retry fetch call present" \
  || fail "/api/gap/work/{id}/retry NOT called"

grep -q 'max_retries_exceeded\|max.retries' "$APP_JS" \
  && ok "max_retries_exceeded response handled" \
  || fail "max_retries_exceeded NOT handled"

grep -q 'data-from-phase\|fromPhase\|from_phase' "$APP_JS" \
  && ok "from_phase param wired to retry call" \
  || fail "from_phase param NOT found"

# ── AC-4: In-flight disabled state ────────────────────────────────────────────
echo "--- AC-4: In-flight disabled state ---"

grep -q '#setRowPending\|setRowPending' "$APP_JS" \
  && ok "setRowPending helper present" \
  || fail "setRowPending helper NOT found"

grep -q 'btn.disabled' "$APP_JS" \
  && ok "buttons disabled during in-flight" \
  || fail "button disabled state NOT found"

grep -q 'gap-row-pending' "$APP_JS" \
  && ok "gap-row-pending class applied during pending" \
  || fail "gap-row-pending class NOT found"

# ── AC-5: CSRF headers ────────────────────────────────────────────────────────
echo "--- AC-5: Auth + CSRF headers on POST calls ---"

grep -q '#gapPostHeaders\|gapPostHeaders' "$APP_JS" \
  && ok "gapPostHeaders helper present" \
  || fail "gapPostHeaders helper NOT found"

grep -q "X-CSRF-Token" "$APP_JS" \
  && ok "X-CSRF-Token header included in POST calls" \
  || fail "X-CSRF-Token NOT found in gap action fetch calls"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
