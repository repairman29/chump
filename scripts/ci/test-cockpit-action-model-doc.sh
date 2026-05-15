#!/usr/bin/env bash
# scripts/ci/test-cockpit-action-model-doc.sh — PRODUCT-120 / PRODUCT-133
#
# Validates that the cockpit doctrine docs are intact + cross-referenced.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
AM="$REPO_ROOT/docs/product/COCKPIT_ACTION_MODEL.md"
SY="$REPO_ROOT/docs/product/COCKPIT_SYNTHESIS.md"
RM="$REPO_ROOT/docs/product/PWA_ROADMAP.md"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

for f in "$AM" "$SY" "$RM"; do
  [ -f "$f" ] || fail "missing doc: $f"
done
ok "all three product docs exist (ACTION_MODEL, SYNTHESIS, ROADMAP)"

# Action Model — the 7 rules + the principle
for rule in "Rule 1" "Rule 2" "Rule 3" "Rule 4" "Rule 5" "Rule 6" "Rule 7"; do
  grep -q "$rule" "$AM" || fail "ACTION_MODEL missing $rule"
done
ok "ACTION_MODEL contains all 7 rules"

grep -q "proposal queue" "$AM" || fail "ACTION_MODEL missing principle 'proposal queue'"
grep -qE "Computer does pattern extraction" "$AM" || fail "ACTION_MODEL missing core principle sentence"
ok "ACTION_MODEL contains the principle"

# Action Model — checklist for new gaps
grep -q "How to apply these rules" "$AM" || fail "ACTION_MODEL missing application checklist"
ok "ACTION_MODEL contains the gap-review checklist"

# Synthesis — algorithm structure
for section in "selection ladder" "Confidence calibration" "Signal cards" "Noise" "Anti-patterns" "How to add a new card"; do
  grep -q "$section" "$SY" || fail "SYNTHESIS missing section: $section"
done
ok "SYNTHESIS contains algorithm spec sections"

# Synthesis — each shipped card type documented
for card in "Today's arc" "No-workers" "Gap-store drift" "Anomaly" "Counter-evidence" "Next decision"; do
  grep -q "$card" "$SY" || fail "SYNTHESIS missing card-type: $card"
done
ok "SYNTHESIS documents all 6 card types"

# Cross-refs
grep -q "COCKPIT_SYNTHESIS" "$AM" || fail "ACTION_MODEL doesn't cross-ref SYNTHESIS"
grep -q "COCKPIT_ACTION_MODEL" "$SY" || fail "SYNTHESIS doesn't cross-ref ACTION_MODEL"
grep -q "PWA_ROADMAP" "$AM" || fail "ACTION_MODEL doesn't cross-ref ROADMAP"
grep -q "PWA_ROADMAP" "$SY" || fail "SYNTHESIS doesn't cross-ref ROADMAP"
ok "cross-references between all three docs present"

# PRODUCT-133 gap filed
[ -f "$REPO_ROOT/docs/gaps/PRODUCT-133.yaml" ] || fail "PRODUCT-133 gap yaml missing"
grep -q "Right-zone action-first" "$REPO_ROOT/docs/gaps/PRODUCT-133.yaml" \
  || fail "PRODUCT-133 title wrong"
ok "PRODUCT-133 gap filed with correct title"

echo
echo "All PRODUCT-120 doctrine + PRODUCT-133 filing tests passed."
