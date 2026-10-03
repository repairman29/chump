#!/usr/bin/env bash
# scripts/ci/test-claim-mode.sh — INFRA-3765 (INFRA-1688 slice)

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

echo "=== INFRA-3765 CHUMP_CLAIM_MODE tests ==="

for sym in \
    "pub enum ClaimMode" \
    "pub fn claim_mode_from_env" \
    "pub fn overlap_outcome" \
    "CHUMP_CLAIM_MODE" \
    "claim_overlap_advisory"; do
    if grep -qF -- "$sym" "$SRC"; then ok "atomic_claim.rs contains $sym"; else fail "missing $sym"; fi
done

if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test -p chump-atomic-claim claim_mode/overlap_outcome ...]"
    if (cd "$REPO_ROOT" && cargo test -p chump-atomic-claim --quiet -- --test-threads=1 \
        claim_mode overlap_outcome claim_overlap_advisory 2>&1 | tail -20); then
        ok "cargo test claim_mode/overlap_outcome passed"
    else
        fail "cargo test claim_mode/overlap_outcome failed"
    fi
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
