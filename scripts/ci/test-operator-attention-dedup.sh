#!/usr/bin/env bash
# scripts/ci/test-operator-attention-dedup.sh — PRODUCT-132
#
# Smoke-tests the within-kind dedup logic in <chump-operator-attention>.
# Validates code structure since this is a UI component (no API).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
JS="$REPO_ROOT/web/v2/operator-attention.js"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$JS" ] || fail "operator-attention.js missing"

# Dedup logic
grep -q "_dedupWithinKind" "$JS" || fail "missing _dedupWithinKind method"
ok "_dedupWithinKind method defined"

# Bucket-aware per-row defer/dismiss
grep -q "_deferBucket"   "$JS" || fail "missing _deferBucket method"
grep -q "_dismissBucket" "$JS" || fail "missing _dismissBucket method"
ok "per-row defer/dismiss promoted to bucket-aware"

# Group-level actions
grep -q "_groupActionsFor" "$JS" || fail "missing _groupActionsFor method"
grep -q "_groupRepair"     "$JS" || fail "missing _groupRepair method"
grep -q "_groupDefer"      "$JS" || fail "missing _groupDefer method"
grep -q "_groupDismiss"    "$JS" || fail "missing _groupDismiss method"
ok "group-level repair/defer/dismiss methods present"

# Repair targets gap_drift_orphan kind specifically
grep -q "gap_drift_orphan" "$JS" || fail "missing gap_drift_orphan kind reference"
grep -q "/api/gap/dep-clean" "$JS" || fail "_groupRepair must POST /api/gap/dep-clean"
ok "Repair drift wires to /api/gap/dep-clean (PRODUCT-127)"

# Visual indicators
grep -q "dedup-hint" "$JS"   || fail "CSS class dedup-hint missing"
grep -q "bucket-count" "$JS" || fail "CSS class bucket-count missing"
grep -q "group-actions" "$JS" || fail "CSS class group-actions missing"
ok "dedup-hint + bucket-count + group-actions CSS classes present"

# Normalization strips leading digits so "6 OPEN" buckets with "226 OPEN"
grep -q "replace(/\^\[\\\\s\\\\d,\]+/" "$JS" \
  || fail "normalization regex (strip leading digits) missing"
ok "note-prefix normalization strips leading digits (counts vary, template same)"

# Per-row click handler uses bucket-aware version
grep -q "_deferBucket(b.closest" "$JS"   || fail "per-row Defer click not bucket-aware"
grep -q "_dismissBucket(b.closest" "$JS" || fail "per-row Dismiss click not bucket-aware"
ok "per-row click handlers route to bucket-aware methods"

echo
echo "All PRODUCT-132 operator-attention dedup smoke tests passed."
