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
    "CHUMP_BYPASS_PROOF_OF_MERGE" \
    "no commit on local main carries this gap ID"; do
    if grep -q "$sym" "$SRC"; then ok "gap_store contains $sym"; else fail "missing $sym"; fi
done

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
