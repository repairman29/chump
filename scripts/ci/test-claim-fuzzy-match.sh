#!/usr/bin/env bash
# scripts/ci/test-claim-fuzzy-match.sh — INFRA-1442

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/atomic_claim.rs"

echo "=== INFRA-1442 claim-time fuzzy-match tests ==="

for sym in \
    "pub struct FuzzyMatch" \
    "pub fn fuzzy_match_open_prs" \
    "pub fn fuzzy_match_active_leases" \
    "pub fn run_fuzzy_gate" \
    "pub fn emit_claim_duplicate_bypassed" \
    "pub fn render_fuzzy_warnings" \
    "force_duplicate" \
    "CHUMP_CLAIM_FUZZY_THRESHOLD" \
    "CHUMP_CLAIM_NO_FUZZY" \
    "claim_duplicate_bypassed" \
    "--force-duplicate"; do
    if grep -q "$sym" "$SRC"; then ok "atomic_claim.rs contains $sym"; else fail "missing $sym"; fi
done

# Unit tests
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test fuzzy_match_tests ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump fuzzy_match_tests --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test fuzzy_match_tests passed"
    else
        fail "cargo test fuzzy_match_tests failed"
    fi
fi

# Integration smoke: fabricate a fixture lease + claim a different gap
# whose title overlaps, assert run_fuzzy_gate (via cargo test target)
# already covers this. Done above.

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
