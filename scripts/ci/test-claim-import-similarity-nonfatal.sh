#!/usr/bin/env bash
# scripts/ci/test-claim-import-similarity-nonfatal.sh — INFRA-3002 AC#2
#
# `chump claim <ID>` seeds a drifted worktree state.db by shelling out to
# `chump gap import`. That import exits 1 whenever ANY row in the yaml
# batch is blocked by INFRA-1434 title-similarity — even a pre-existing
# dupe totally unrelated to the gap being claimed. Before this fix that
# nonzero exit made run_chump_gap_import() bail, which failed the whole
# `chump claim` call even though the claimed gap itself was never part of
# the block. Genuine import failures (yaml parse errors etc.) must still
# be fatal.
set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

echo "=== INFRA-3002 AC#2 — claim survives unrelated import-similarity blocks ==="
echo

for sym in \
    "fn import_failure_is_similarity_block_only" \
    "import_failure_similarity_block_is_recoverable" \
    "import_failure_parse_error_is_still_fatal"; do
    if grep -qF -- "$sym" "$SRC"; then ok "atomic_claim.rs contains $sym"; else fail "missing $sym"; fi
done

if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test -p chump-atomic-claim import_failure ...]"
    if (cd "$REPO_ROOT" && cargo test -p chump-atomic-claim import_failure --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test import_failure_* passed"
    else
        fail "cargo test import_failure_* failed"
    fi
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
