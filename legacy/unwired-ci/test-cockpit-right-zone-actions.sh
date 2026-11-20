#!/usr/bin/env bash
# scripts/ci/test-cockpit-right-zone-actions.sh — PRODUCT-133
#
# Smoke-tests the right-zone action overlay (web/v2/cockpit.js).
# Validates code structure since this is a UI component (no API).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
JS="$REPO_ROOT/web/v2/cockpit.js"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$JS" ] || fail "cockpit.js missing"

# Overlay element + render method
grep -q 'id="right-actions"' "$JS"      || fail "right-actions overlay element missing"
grep -q '#renderRightZoneAction'        "$JS" || fail "#renderRightZoneAction method missing"
grep -q 'this.#renderRightZoneAction(inputs)' "$JS" \
  || fail "renderRightZoneAction not called from synthesize()"
ok "right-actions overlay + render method wired"

# 3 action variants present
grep -q 'Fleet parked'                     "$JS" || fail "missing 'Fleet parked' read"
grep -q 'Autopilot on, ambient sparse'     "$JS" || fail "missing 'autopilot wedged' read"
grep -q 'Ambient stream sparse'            "$JS" || fail "missing 'ambient sparse' read"
ok "3 action-variant reads present"

# Each variant has a primary action button with data-action-view
grep -q 'data-action-view="wake-fleet"'    "$JS" || fail "wake-fleet action button missing"
grep -q 'data-action-view="restart-fleet"' "$JS" || fail "restart-fleet action button missing"
grep -q 'data-action-view="copy-tail"'     "$JS" || fail "copy-tail action button missing"
ok "all 3 buttons use data-action-view (consumed by #onCardAction)"

# copy-tail handler exists in #onCardAction
grep -q "view === 'copy-tail'"             "$JS" || fail "copy-tail handler missing in #onCardAction"
grep -q "tail -f .chump-locks/ambient.jsonl" "$JS" \
  || fail "copy-tail command string missing"
ok "copy-tail handler wired with the correct tail command"

# Decision ladder is the right shape (first-match-wins, hides if none)
grep -q "overlay.setAttribute('hidden'"    "$JS" || fail "overlay must hide when no proposal"
ok "overlay hides when right zone is fine as-is"

# CSS for overlay
grep -q '\.right-actions {'                "$JS" || fail ".right-actions CSS missing"
grep -q '\.right-actions-btn'              "$JS" || fail ".right-actions-btn CSS missing"
grep -q '\.right-actions\[hidden\]'        "$JS" || fail "hidden-state CSS missing"
ok "overlay CSS shipped (3 selectors)"

# Reuses synth inputs — no new fetch
if grep -A 20 '#renderRightZoneAction' "$JS" | grep -q 'await fetch\|new XMLHttpRequest'; then
  fail "right-zone renderer should NOT fetch — must reuse synth inputs"
fi
ok "renderer reuses synth inputs (no extra fetch)"

# Decision ladder honors action-model Rule 2 (empty state IS the button)
grep -B 1 -A 6 "Fleet parked" "$JS" | grep -q 'Wake fleet' \
  || fail "Fleet parked variant must surface [Wake fleet] button"
ok "action-model Rule 2: empty state IS the button (Fleet parked → Wake fleet)"

echo
echo "All PRODUCT-133 right-zone action overlay smoke tests passed."
