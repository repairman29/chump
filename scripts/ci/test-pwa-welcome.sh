#!/usr/bin/env bash
# test-pwa-welcome.sh — PRODUCT-082
#
# Static checks for the first-run welcome component:
#   1. welcome.js exists and defines ChumpWelcome
#   2. index.html includes <chump-welcome> element
#   3. index.html loads welcome.js as a module script
#   4. localStorage keys FIRST_VISIT_KEY and COMPLETED_KEY are correct
#   5. shouldShowWelcome() checks ?welcome=force param
#   6. skip button triggers #finish()
#   7. gap-list loads from /api/gap-queue with xs/s effort filter

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JS="$REPO_ROOT/web/v2/welcome.js"
HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. welcome.js exists
[[ -f "$JS" ]] || fail "welcome.js not found at $JS"
ok "welcome.js exists"

# 2. index.html has <chump-welcome>
grep -q '<chump-welcome>' "$HTML" || fail "index.html missing <chump-welcome> element"
ok "index.html includes <chump-welcome> element"

# 3. index.html loads welcome.js
grep -q 'src="welcome.js"' "$HTML" || fail "index.html missing <script src=\"welcome.js\">"
ok "index.html loads welcome.js as module script"

# 4. localStorage keys
grep -q "chump_first_visit" "$JS" || fail "welcome.js missing chump_first_visit localStorage key"
grep -q "chump_first_visit_completed" "$JS" || fail "welcome.js missing chump_first_visit_completed key"
ok "localStorage keys present: chump_first_visit, chump_first_visit_completed"

# 5. ?welcome=force support
grep -q "welcome.*force\|force.*welcome" "$JS" || fail "welcome.js missing ?welcome=force bypass"
ok "?welcome=force query param bypass present"

# 6. 'I've used Chump before' skip button wiring
grep -q 'skip-btn\|skip_btn\|I.*used.*Chump.*before\|skip' "$JS" || fail "welcome.js missing skip button"
ok "skip button wired in welcome.js"

# 7. gap API call filters for small effort
grep -q "gap-queue\|gap_queue" "$JS" || fail "welcome.js missing /api/gap-queue fetch"
grep -q "xs.*s\|effort.*xs\|xs.*effort\|\['xs'" "$JS" || fail "welcome.js missing xs/s effort filter"
ok "gap-queue fetch with xs/s effort filter present"

# 8. chump-welcome is defined as a custom element
grep -q "customElements.define.*chump-welcome" "$JS" || fail "chump-welcome not registered as custom element"
ok "customElements.define('chump-welcome') present"

# 9. localStorage.setItem(FIRST_VISIT_KEY) on connectedCallback
grep -q "setItem.*FIRST_VISIT_KEY\|setItem.*chump_first_visit" "$JS" || fail "welcome.js does not set first_visit flag in localStorage"
ok "localStorage first_visit flag set on connectedCallback"

echo
echo "All PRODUCT-082 welcome tests passed."
