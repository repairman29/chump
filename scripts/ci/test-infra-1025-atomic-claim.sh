#!/usr/bin/env bash
# test-infra-1025-atomic-claim.sh — INFRA-1025
#
# Source-level assertions that atomic_claim.rs no longer shells out to
# gap-claim.sh and that gap-claim.sh is now a thin wrapper.
# Also verifies --resume flag is parsed and rollback helpers exist.
# No binary build required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ATOMIC="$REPO_ROOT/src/atomic_claim.rs"
GAP_CLAIM="$REPO_ROOT/scripts/coord/gap-claim.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1025 atomic claim — no-shell-out + thin-wrapper assertions ==="
echo

# ── src/atomic_claim.rs ───────────────────────────────────────────────────────
echo "--- src/atomic_claim.rs ---"

# AC1: gap-claim.sh shell-out must be GONE from run_claim() — look for actual
# exec pattern (arg to Command::new or .arg()), not comments.
grep -qE '\.arg\(.*gap-claim\.sh|Command::new.*gap-claim\.sh|bash.*gap-claim\.sh' "$ATOMIC" \
  && fail "gap-claim.sh exec shell-out still present in atomic_claim.rs" \
  || ok "gap-claim.sh exec shell-out removed from atomic_claim.rs"

# AC1: write_db_claim function present (state.db leases written in Rust)
grep -q 'fn write_db_claim' "$ATOMIC" \
  && ok "write_db_claim function present" \
  || fail "write_db_claim function NOT found"

# AC1: write_or_merge_lease called inside run_claim
grep -q 'write_or_merge_lease' "$ATOMIC" \
  && ok "write_or_merge_lease called (JSON lease write)" \
  || fail "write_or_merge_lease NOT called"

# AC1: nats_dual_write called in run_claim
grep -q 'nats_dual_write' "$ATOMIC" \
  && ok "nats_dual_write present (cross-machine serialization)" \
  || fail "nats_dual_write NOT called"

# AC6: --resume flag in ClaimArgs
grep -q 'pub resume: bool\|resume: bool' "$ATOMIC" \
  && ok "--resume flag present in ClaimArgs" \
  || fail "--resume flag NOT found"

# AC6: remote_branch_exists function
grep -q 'fn remote_branch_exists' "$ATOMIC" \
  && ok "remote_branch_exists function present" \
  || fail "remote_branch_exists NOT found"

# AC6: INFRA-1025 referenced in atomic_claim.rs
grep -q 'INFRA-1025' "$ATOMIC" \
  && ok "INFRA-1025 referenced in atomic_claim.rs" \
  || fail "INFRA-1025 NOT referenced"

# Rollback: rollback_wt closure present
grep -q 'rollback_wt' "$ATOMIC" \
  && ok "rollback_wt rollback helper present" \
  || fail "rollback_wt NOT found (AC1: rollback on failure)"

# ── scripts/coord/gap-claim.sh ────────────────────────────────────────────────
echo "--- scripts/coord/gap-claim.sh ---"

# INFRA-987: gap-claim.sh was deleted (final state). Accept either:
#   a) File deleted (INFRA-987 complete) — all three ACs pass trivially.
#   b) File is ≤35-line thin wrapper delegating to chump claim (INFRA-985 intermediate).
if [[ ! -f "$GAP_CLAIM" ]]; then
    ok "gap-claim.sh deleted (INFRA-987 complete — fully replaced by chump claim)"
    ok "gap-claim.sh exec-delegates to chump claim (N/A: file deleted)"
    ok "gap-claim.sh does not contain old shell logic (N/A: file deleted)"
else
    # AC2: gap-claim.sh must be ≤ 35 lines (thin wrapper)
    LINE_COUNT="$(wc -l < "$GAP_CLAIM")"
    if [[ "$LINE_COUNT" -le 35 ]]; then
        ok "gap-claim.sh is thin wrapper ($LINE_COUNT lines ≤ 35)"
    else
        fail "gap-claim.sh is still $LINE_COUNT lines (expected ≤ 35 for thin wrapper)"
    fi

    # AC2: exec chump claim present
    grep -q 'exec.*chump.*claim\|exec.*"\$CHUMP".*claim' "$GAP_CLAIM" \
      && ok "gap-claim.sh exec-delegates to chump claim" \
      || fail "gap-claim.sh does NOT delegate to chump claim"

    # AC2: gap-claim.sh must not contain the old bash logic
    grep -q 'NATS_ENABLED\|write.*lease\|SESSION_ID=.*date' "$GAP_CLAIM" \
      && fail "gap-claim.sh still contains old shell logic" \
      || ok "gap-claim.sh does not contain old shell logic"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
