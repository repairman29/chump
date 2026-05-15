#!/usr/bin/env bash
# scripts/ci/test-pwa-roadmap.sh — PRODUCT-121
#
# Smoke-tests the PWA roadmap doc + verifies every existing PWA gap is
# phase-tagged so the picker can act on it.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
DOC="$REPO_ROOT/docs/product/PWA_ROADMAP.md"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$DOC" ] || fail "docs/product/PWA_ROADMAP.md missing"
ok "roadmap doc exists"

# Doc structure
for section in \
  "Cockpit principles" \
  "Phase 1 — Cockpit-MVP" \
  "Phase 2 — Inbox" \
  "Phase 3 — Fleet Grading" \
  "Phase 4 — Demo Mode" \
  "Operator sign-off checklist"
do
  grep -q "$section" "$DOC" || fail "missing section: $section"
done
ok "all 4 phases + principles + sign-off section present"

# Each phase has a ship criterion
sc_count=$(grep -c "Ship criterion" "$DOC")
[ "$sc_count" -ge 3 ] || fail "expected >=3 'Ship criterion' markers, got $sc_count"
ok "ship criteria present ($sc_count found)"

# Operator sign-off section has at least 5 checklist items
checklist_count=$(grep -c '^- \[ \]' "$DOC")
[ "$checklist_count" -ge 5 ] || fail "operator sign-off checklist needs >=5 items, got $checklist_count"
ok "operator sign-off checklist has $checklist_count items"

# Each Phase-1 gap is phase-tagged in its YAML
phase1_gaps=(PRODUCT-115 PRODUCT-117 PRODUCT-078 PRODUCT-083 PRODUCT-080 INFRA-1303)
for g in "${phase1_gaps[@]}"; do
  f="$REPO_ROOT/docs/gaps/$g.yaml"
  [ -f "$f" ] || fail "gap YAML missing: $g.yaml"
  grep -q "PWA phase: 1" "$f" || fail "$g missing 'PWA phase: 1' note"
done
ok "all Phase 1 gaps phase-tagged (${#phase1_gaps[@]})"

# Phase 2-4 also tagged (gap:phase format for bash 3.2 portability)
phase_24_pairs="PRODUCT-084:2 PRODUCT-085:2 PRODUCT-086:2 PRODUCT-102:2
PRODUCT-081:3 PRODUCT-055:3 PRODUCT-060:3
PRODUCT-087:4 INFRA-1276:4"
count_24=0
for pair in $phase_24_pairs; do
  g="${pair%:*}"; ph="${pair#*:}"
  f="$REPO_ROOT/docs/gaps/$g.yaml"
  [ -f "$f" ] || fail "gap YAML missing: $g"
  grep -q "PWA phase: $ph" "$f" \
    || fail "$g missing 'PWA phase: $ph' note"
  count_24=$((count_24 + 1))
done
ok "all Phase 2-4 gaps phase-tagged ($count_24)"

# INFRA-1276 must be P3 (demoted)
grep -q '^[[:space:]]*priority: P3' "$REPO_ROOT/docs/gaps/INFRA-1276.yaml" \
  || fail "INFRA-1276 not demoted to P3 as roadmap specifies"
ok "INFRA-1276 demoted P2→P3 per roadmap"

# Roadmap cross-references the right related gaps
for ref in CREDIBLE-068 CREDIBLE-069 PRODUCT-119 PRODUCT-120; do
  grep -q "$ref" "$DOC" || fail "roadmap missing cross-reference to $ref"
done
ok "cross-references to related gaps present"

# "What does NOT belong" list keeps CI/CLI gaps out
for nonpwa in INFRA-1142 INFRA-1285 FLEET-037; do
  grep -q "$nonpwa" "$DOC" || fail "roadmap should exclude $nonpwa explicitly"
done
ok "non-PWA gaps explicitly excluded from PWA backlog"

echo
echo "All PRODUCT-121 PWA-roadmap smoke tests passed."
