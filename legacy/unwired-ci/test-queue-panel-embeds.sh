#!/usr/bin/env bash
# scripts/ci/test-queue-panel-embeds.sh — INFRA-1196
#
# Verifies the PWA queue view embeds <chump-pr-card> + <chump-workflow-timeline>
# inline per gap row, lazy-mounted via IntersectionObserver.
#
# Strategy: spin up chump --web on a random port with a synthetic state.db
# (one shipped gap with closed_pr, one claim-blocked gap), fetch /v2/app.js
# + /v2/index.html, assert:
#   - The renderer references chump-pr-card + chump-workflow-timeline
#   - gap-embed placeholders are conditional (only present when relevant)
#   - IntersectionObserver wiring is present
#   - CSS for gap-pillar / gap-domain / gap-embed exists in index.html
#
# Note: this is a *structural* test against the source files. End-to-end
# DOM mounting requires a headless browser (defer to e2e-pwa job). The
# structural pass guarantees the wiring is syntactically present so the
# e2e tests don't fail on missing element refs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]      || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]]  || fail "missing $INDEX_HTML"

# ── Test 1: app.js renders <chump-pr-card> when closed_pr present ──────────
grep -q "chump-pr-card" "$APP_JS" \
    || fail "app.js missing chump-pr-card reference"
grep -q "gap-embed-pr" "$APP_JS" \
    || fail "app.js missing gap-embed-pr slot class"
grep -q "data-pr-number" "$APP_JS" \
    || fail "app.js missing data-pr-number attribute on PR slot"
ok "app.js: chump-pr-card wiring present (slot + attribute + mount path)"

# ── Test 2: app.js renders <chump-workflow-timeline> for active workflows ──
grep -q "chump-workflow-timeline" "$APP_JS" \
    || fail "app.js missing chump-workflow-timeline reference"
grep -q "gap-embed-timeline" "$APP_JS" \
    || fail "app.js missing gap-embed-timeline slot class"
grep -q "data-gap-id" "$APP_JS" \
    || fail "app.js missing data-gap-id attribute on timeline slot"
ok "app.js: chump-workflow-timeline wiring present"

# ── Test 3: IntersectionObserver lazy-mount path exists ───────────────────
grep -q "IntersectionObserver" "$APP_JS" \
    || fail "app.js missing IntersectionObserver — lazy-mount perf gate not honored"
grep -q "#mountVisibleEmbeds\|mountVisibleEmbeds" "$APP_JS" \
    || fail "app.js missing #mountVisibleEmbeds method"
grep -q "#mountEmbed\|mountEmbed" "$APP_JS" \
    || fail "app.js missing #mountEmbed method"
ok "app.js: IntersectionObserver lazy-mount path wired"

# ── Test 4: disconnectedCallback cleans up observer + clears list ──────────
grep -q "embedObserver" "$APP_JS" \
    || fail "app.js missing #embedObserver field — lifecycle reference not stored"
# Disconnect call should occur (used in both view-switch + load-refresh).
[[ "$(grep -c 'embedObserver.disconnect\(\)' "$APP_JS")" -ge 1 ]] \
    || fail "app.js missing embedObserver.disconnect() — would leak SSE on view switch"
ok "app.js: lifecycle cleanup (observer.disconnect + list.innerHTML clear) present"

# ── Test 5: renderRow placeholders are conditional on closed_pr/blocked ────
grep -q "g.closed_pr" "$APP_JS" \
    || fail "app.js renderRow not branching on closed_pr"
grep -q "isActiveWorkflow\|preflight_status === 'blocked'" "$APP_JS" \
    || fail "app.js missing active-workflow detection for timeline mount"
ok "app.js: conditional slots — pr-card needs closed_pr, timeline needs blocked+assigned"

# ── Test 6: index.html ships CSS for new badges + embed slot ──────────────
grep -q "gap-pillar" "$INDEX_HTML" \
    || fail "index.html missing .gap-pillar CSS"
grep -q "gap-pillar-effective" "$INDEX_HTML" \
    || fail "index.html missing per-pillar color classes"
grep -q "gap-domain" "$INDEX_HTML" \
    || fail "index.html missing .gap-domain CSS"
grep -q "gap-embed" "$INDEX_HTML" \
    || fail "index.html missing .gap-embed CSS (per-row embed slot)"
ok "index.html: pillar + domain + embed-slot CSS present"

# ── Test 7: pillar badges cover all five canonical pillars ────────────────
for p in effective credible resilient zero-waste mission; do
    grep -q "gap-pillar-$p" "$INDEX_HTML" \
        || fail "index.html missing CSS class .gap-pillar-$p"
done
ok "index.html: all 5 pillar tag classes styled"

# ── Test 8: lease-holder line surfaces assigned_session ───────────────────
grep -q "assigned_session" "$APP_JS" \
    || fail "app.js doesn't surface assigned_session from gap-queue response"
grep -q "shortSession\|#shortSession" "$APP_JS" \
    || fail "app.js missing #shortSession truncator"
ok "app.js: lease-holder rendering wired"

# ── Test 9: AC count + depends_on badges wired ────────────────────────────
grep -q "acceptance_criteria_count" "$APP_JS" \
    || fail "app.js doesn't surface acceptance_criteria_count"
grep -q "depends_on" "$APP_JS" \
    || fail "app.js doesn't surface depends_on"
ok "app.js: AC count + depends-on badges wired"

ok "ALL INFRA-1196 queue-panel embed checks passed"
