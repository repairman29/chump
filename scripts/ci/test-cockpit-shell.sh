#!/usr/bin/env bash
# scripts/ci/test-cockpit-shell.sh — PRODUCT-122
#
# Smoke-tests the Phase 1 Cockpit-MVP shell composition.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
JS="$REPO_ROOT/web/v2/cockpit.js"
HTML="$REPO_ROOT/web/v2/index.html"
APP="$REPO_ROOT/web/v2/app.js"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$JS" ] || fail "cockpit.js missing"

grep -q "customElements.define('chump-view-cockpit'" "$JS" \
  || fail "must define <chump-view-cockpit>"
ok "<chump-view-cockpit> custom element defined"

grep -q 'src="cockpit.js"' "$HTML" \
  || fail "cockpit.js not registered in index.html"
ok "cockpit.js script tag in index.html"

grep -qE "cockpit:[[:space:]]*\(\)[[:space:]]*=>[[:space:]]*document.createElement\('chump-view-cockpit'\)" "$APP" \
  || fail "VIEWS map missing cockpit entry"
ok "VIEWS['cockpit'] wired in app.js"

# 5-zone composition — each existing component referenced by tag name
for tag in chump-operator-attention chump-inbox chump-fleet-sidebar chump-ambient-viewer chump-quick-actions; do
  grep -q "$tag" "$JS" || fail "cockpit must mount $tag"
done
ok "5 existing components composed (attention/inbox/fleet/ambient/quick-actions)"

# Zone areas present
for area in 'grid-template-areas' 'zone-left' 'zone-center' 'zone-right' 'zone-footer'; do
  grep -q "$area" "$JS" || fail "missing zone class: $area"
done
ok "5-zone CSS grid layout defined"

# Three first-thing questions surfaced in headers (PRODUCT-121 principle)
grep -q "What needs me" "$JS"     || fail "left zone must surface 'What needs me?' question"
grep -q "What did the fleet" "$JS" || fail "center zone must surface 'What did the fleet do?' question"
grep -q "What's running" "$JS"     || fail "right zone must surface 'What's running?' question"
ok "three first-thing questions surfaced as zone headers"

# Ambient collapsible per PRODUCT-121 open question #2
grep -q 'ambient-toggle' "$JS"   || fail "ambient must be toggleable"
grep -q 'ambient-collapsed' "$JS" || fail "ambient must default-collapse"
ok "ambient stream collapsible (default collapsed)"

# Narrow viewport stack
grep -q '@media (max-width: 1000px)' "$JS" \
  || fail "must collapse to single column on narrow viewport"
ok "narrow-viewport stack layout present"

# No new custom elements (composition-only AC)
new_defs=$(grep -c "customElements.define" "$JS")
[ "$new_defs" -eq 1 ] \
  || fail "cockpit.js defines $new_defs custom elements; composition-only AC requires exactly 1"
ok "composition-only: exactly 1 new custom element (the cockpit view itself)"

echo
echo "All PRODUCT-122 cockpit-shell smoke tests passed."
