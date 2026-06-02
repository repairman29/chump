#!/usr/bin/env bash
# scripts/ci/test-status-flip-proof-of-merge.sh — INFRA-1392

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"

echo "=== INFRA-1392 status PROOF-OF-MERGE tests ==="

for sym in \
    "pub fn verify_proof_of_merge" \
    "INFRA-1392 PROOF-OF-MERGE" \
    "no commit on local main carries this gap ID"; do
    if grep -q "$sym" "$SRC"; then ok "gap_store contains $sym"; else fail "missing $sym"; fi
done
# INFRA-2423: CHUMP_BYPASS_PROOF_OF_MERGE is deleted; chump gap ship now
# auto-fetches origin/main before the proof-of-merge check. Verify the bypass
# var is gone from source.
if grep -q "CHUMP_BYPASS_PROOF_OF_MERGE" "$SRC"; then
    fail "CHUMP_BYPASS_PROOF_OF_MERGE still present in $SRC (should be deleted per INFRA-2423)"
else
    ok "CHUMP_BYPASS_PROOF_OF_MERGE is absent from gap_store (INFRA-2423)"
fi

if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    if (cd "$REPO_ROOT" && cargo test -p chump-gap-store proof_of_merge --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test proof_of_merge passed"
    else
        fail "cargo test proof_of_merge failed"
    fi
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
