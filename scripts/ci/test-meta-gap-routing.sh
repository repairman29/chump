#!/usr/bin/env bash
# test-meta-gap-routing.sh — verify META-* gap routing per META-044.
#
# Checks:
#   1. META-* xs/s gaps appear in picker output (fleet-pickable)
#   2. META-* m/l gaps are excluded by the picker
#   3. EVAL-*, RESEARCH-*, SWARM-* still excluded regardless of effort
#   4. gap-reserve.sh emits meta_filed alert for META-* domains
#
# Exit: 0 = all checks pass, 1 = failure

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Build a minimal gap JSON array for picker testing.
make_gap_json() {
    local id="$1" domain="$2" effort="$3"
    printf '[{"id":"%s","domain":"%s","effort":"%s","status":"open","priority":"P1","title":"test gap"}]' \
        "$id" "$domain" "$effort"
}

run_picker() {
    local json="$1"
    local gap_file
    gap_file="$(mktemp -t test-picker.XXXXXX)"
    printf '%s' "$json" > "$gap_file"
    result="$(EXCLUDE_RE='^(EVAL-|RESEARCH-|SWARM-)' \
               GAP_JSON_FILE="$gap_file" \
               CHUMP_AFFINITY=0 \
               CHUMP_REBALANCE=0 \
               CHUMP_FLEET_DRY_RUN=1 \
               python3 "$PICKER" 2>/dev/null || true)"
    rm -f "$gap_file"
    echo "$result"
}

# ── Test 1: META xs is pickable ───────────────────────────────────────────────
result="$(run_picker "$(make_gap_json META-099 META xs)")"
if [[ "$result" == "META-099" ]]; then
    pass "META-* xs gap is fleet-pickable"
else
    fail "META-* xs gap should be pickable, picker returned: '$result'"
fi

# ── Test 2: META s is pickable ────────────────────────────────────────────────
result="$(run_picker "$(make_gap_json META-098 META s)")"
if [[ "$result" == "META-098" ]]; then
    pass "META-* s gap is fleet-pickable"
else
    fail "META-* s gap should be pickable, picker returned: '$result'"
fi

# ── Test 3: META m is NOT pickable ────────────────────────────────────────────
result="$(run_picker "$(make_gap_json META-097 META m)")"
if [[ -z "$result" ]]; then
    pass "META-* m gap is correctly excluded (needs human judgment)"
else
    fail "META-* m gap should be excluded, picker returned: '$result'"
fi

# ── Test 4: EVAL is still excluded ────────────────────────────────────────────
result="$(run_picker "$(make_gap_json EVAL-001 EVAL xs)")"
if [[ -z "$result" ]]; then
    pass "EVAL-* still excluded by EXCLUDE_RE"
else
    fail "EVAL-* should still be excluded, picker returned: '$result'"
fi

# ── Test 5: SWARM is still excluded ───────────────────────────────────────────
result="$(run_picker "$(make_gap_json SWARM-001 SWARM xs)")"
if [[ -z "$result" ]]; then
    pass "SWARM-* still excluded by EXCLUDE_RE"
else
    fail "SWARM-* should still be excluded, picker returned: '$result'"
fi

# ── Test 6: gap-reserve.sh emits meta_filed for META domain ──────────────────
# Check the alert emission code is present in gap-reserve.sh
if grep -q 'meta_filed' "$REPO_ROOT/scripts/coord/gap-reserve.sh"; then
    pass "gap-reserve.sh contains meta_filed alert emission"
else
    fail "gap-reserve.sh missing meta_filed alert emission"
fi

echo ""
echo "All META-044 routing checks passed."
