#!/usr/bin/env bash
# test-pwa-verb-nav.sh — PRODUCT-083
#
# Static checks for the verb-shaped quick-actions panel:
#   1. quick-actions.js exists and defines ChumpQuickActions
#   2. index.html includes <chump-quick-actions> element
#   3. index.html loads quick-actions.js as module script
#   4. All 6 verb buttons are defined with correct data-view targets
#   5. Keyboard shortcuts (T R S C B ?) are declared in ACTIONS
#   6. Help verb triggers welcome?welcome=force (not a plain view navigate)
#   7. Mobile hamburger element is present
#   8. chump:navigate-action secondary event is dispatched for filtered verbs

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JS="$REPO_ROOT/web/v2/quick-actions.js"
HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. quick-actions.js exists
[[ -f "$JS" ]] || fail "quick-actions.js not found at $JS"
ok "quick-actions.js exists"

# 2. index.html has <chump-quick-actions>
grep -q '<chump-quick-actions>' "$HTML" || fail "index.html missing <chump-quick-actions> element"
ok "index.html includes <chump-quick-actions> element"

# 3. index.html loads quick-actions.js
grep -q 'src="quick-actions.js"' "$HTML" || fail "index.html missing <script src=\"quick-actions.js\">"
ok "index.html loads quick-actions.js"

# 4. All 6 verb buttons defined with correct data-view targets
for target in agents results judgment settings tasks welcome; do
  grep -q "view.*['\"]${target}['\"]" "$JS" || fail "quick-actions.js missing data-view='${target}'"
done
ok "All 6 verb data-view targets present: agents results judgment settings tasks welcome"

# 5. Keyboard shortcuts T R S C B ? declared in ACTIONS array
for key in T R S C B '?'; do
  grep -q "key.*['\"]${key}['\"]" "$JS" || fail "quick-actions.js missing keyboard shortcut '${key}'"
done
ok "Keyboard shortcuts T R S C B ? declared in ACTIONS"

# 6. Help verb triggers welcome=force URL (not a plain navigate)
grep -q "welcome.*force\|force.*welcome" "$JS" || fail "quick-actions.js missing welcome=force for Help verb"
ok "Help verb triggers ?welcome=force redirect"

# 7. Mobile hamburger element present
grep -q "qa-hamburger\|hamburger" "$JS" || fail "quick-actions.js missing hamburger element for mobile"
ok "Mobile hamburger overlay element present"

# 8. chump:navigate-action secondary event dispatched
grep -q "chump:navigate-action" "$JS" || fail "quick-actions.js missing chump:navigate-action event dispatch"
ok "chump:navigate-action secondary event dispatched for filtered verbs"

# 9. customElements.define for chump-quick-actions
grep -q "customElements.define.*chump-quick-actions" "$JS" || fail "chump-quick-actions not registered as custom element"
ok "customElements.define('chump-quick-actions') present"

echo
echo "All PRODUCT-083 verb-nav tests passed."
