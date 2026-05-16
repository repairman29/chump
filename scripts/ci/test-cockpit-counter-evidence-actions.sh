#!/usr/bin/env bash
# test-cockpit-counter-evidence-actions.sh — PRODUCT-131
#
# Verifies Counter-evidence cards have actionable buttons (not just 'see GH'):
#   1. counter-evidence card declares action_kind-specific actions
#   2. 'Draft outreach' view is implemented and primary
#   3. 'Bump priority' view exists with a target gap_id
#   4. Draft-outreach handler builds a prefilled template (clipboard or mailto)
#   5. Bump-priority handler offers CLI fallback (chump gap set --priority)
#   6. docs/product/COCKPIT_ACTION_MODEL.md exists (action ladder)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COCKPIT="$REPO_ROOT/web/v2/cockpit.js"
ACTION_MODEL="$REPO_ROOT/docs/product/COCKPIT_ACTION_MODEL.md"

echo "=== PRODUCT-131 cockpit counter-evidence actions ==="

[[ -f "$COCKPIT" ]] || { echo "FAIL: $COCKPIT missing"; exit 2; }

# ── AC #1: counter-evidence card declares action_kind-specific actions ──────
# Card uses view: 'draft-outreach' + view: 'bump-priority' as a stand-in for
# the conceptual action_kind field (the dispatcher resolves view → action).
card_block="$(grep -A20 "Counter-evidence — 0 external dogfooders" "$COCKPIT")"
if echo "$card_block" | grep -q "Draft outreach.*primary: true"; then
    ok "AC #1: Draft outreach declared as primary action"
else
    fail "AC #1: Draft outreach primary missing"
fi
if echo "$card_block" | grep -q "Bump P2→P1\|Bump.*priority"; then
    ok "AC #1: Bump priority action present"
else
    fail "AC #1: Bump priority action missing"
fi

# ── AC #2: draft-outreach handler exists ───────────────────────────────────
if grep -q "if (view === 'draft-outreach')" "$COCKPIT"; then
    ok "AC #2: draft-outreach handler dispatch present"
else
    fail "AC #2: draft-outreach handler missing"
fi

# Scope: pull just the draft-outreach handler body.
draft_block="$(grep -A30 "view === 'draft-outreach'" "$COCKPIT")"

# ── AC #4: handler prefills a template (clipboard or mailto) ────────────────
if echo "$draft_block" | grep -q "navigator.clipboard.writeText" \
   && echo "$draft_block" | grep -q "mailto:"; then
    ok "AC #4: draft-outreach prefills template (clipboard + mailto fallback)"
else
    fail "AC #4: draft-outreach template/fallback missing"
fi

# Template contains key recruitment marks
for needle in "experimental coordination platform" "dogfood" "Interested"; do
    if echo "$draft_block" | grep -q "$needle"; then
        ok "draft-outreach template includes '$needle'"
    else
        fail "draft-outreach template missing '$needle'"
    fi
done

# ── AC #3: bump-priority handler exists ─────────────────────────────────────
if grep -q "if (view === 'bump-priority' && gapId)" "$COCKPIT"; then
    ok "AC #3: bump-priority handler dispatch present + accepts gapId"
else
    fail "AC #3: bump-priority handler missing"
fi

bump_block="$(grep -A15 "view === 'bump-priority'" "$COCKPIT")"

# ── AC #5: bump-priority handler offers CLI fallback ────────────────────────
if echo "$bump_block" | grep -q "chump gap set.*--priority P1"; then
    ok "AC #5: bump-priority offers chump gap set CLI fallback"
else
    fail "AC #5: bump-priority CLI fallback missing"
fi

# ── AC #6: docs/product/COCKPIT_ACTION_MODEL.md exists ──────────────────────
if [[ -f "$ACTION_MODEL" ]]; then
    ok "AC #6: docs/product/COCKPIT_ACTION_MODEL.md present"
else
    fail "AC #6: docs/product/COCKPIT_ACTION_MODEL.md missing"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
