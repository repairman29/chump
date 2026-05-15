#!/usr/bin/env bash
# scripts/ci/test-claim-ac-gate.sh — INFRA-1259
#
# Verifies the chump-gap-store vague-AC gate (claim) and the
# chump-orchestrator vague-AC filter (picker).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_STORE="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"
SRC_ORCH="$REPO_ROOT/crates/chump-orchestrator/src/lib.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. Helper present in chump-gap-store (claim-time gate)
grep -q "pub fn is_vague_acceptance_criteria" "$SRC_STORE" \
    || fail "gap-store: missing is_vague_acceptance_criteria"
ok "gap-store: is_vague_acceptance_criteria helper exposed"

# 2. claim() refuses vague AC unless bypass set
grep -q "is_vague_acceptance_criteria(&ac_raw)" "$SRC_STORE" \
    || fail "gap-store::claim does not gate on vague AC"
grep -q "CHUMP_ALLOW_VAGUE_AC" "$SRC_STORE" \
    || fail "gap-store::claim missing bypass env var"
grep -q "no real acceptance criteria" "$SRC_STORE" \
    || fail "gap-store::claim missing actionable error message"
ok "gap-store::claim gates on vague AC + supports CHUMP_ALLOW_VAGUE_AC bypass"

# 3. Helper present in chump-orchestrator (picker filter)
grep -q "pub fn is_vague_acceptance_criteria" "$SRC_ORCH" \
    || fail "orchestrator: missing is_vague_acceptance_criteria"
ok "orchestrator: is_vague_acceptance_criteria helper exposed"

# 4. Gap struct has acceptance_criteria field (so picker can read it)
grep -q "pub acceptance_criteria" "$SRC_ORCH" \
    || fail "orchestrator: Gap struct missing acceptance_criteria field"
ok "orchestrator: Gap struct exposes acceptance_criteria"

# 5. Picker filters vague gaps
grep -q "picker_skipped_vague_ac" "$SRC_ORCH" \
    || fail "orchestrator: picker missing vague-AC telemetry"
grep -q "is_vague_acceptance_criteria(g.acceptance_criteria.as_ref())" "$SRC_ORCH" \
    || fail "orchestrator: picker not invoking vague filter on Gap"
ok "orchestrator: pick_gap_with_kind skips vague-AC gaps with telemetry"

# 6. Both crates: dedicated tests for the gate / filter exist
grep -q "claim_rejects_vague_ac_without_bypass\|claim_rejects_vague_ac" "$SRC_STORE" \
    || fail "gap-store: missing dedicated vague-AC-rejection test"
grep -q "pick_gap_skips_vague_ac" "$SRC_ORCH" \
    || fail "orchestrator: missing dedicated picker vague-AC test"
ok "dedicated rust unit tests cover gate (gap-store) + filter (orchestrator)"

# 7. Build both crates — fast sanity (full cargo test is run in fast-checks)
(cd "$REPO_ROOT" && cargo check -p chump-gap-store -p chump-orchestrator --quiet 2>&1) \
    || fail "cargo check failed for chump-gap-store / chump-orchestrator"
ok "both crates cargo-check clean"

echo
echo "All INFRA-1259 claim-AC-gate tests passed."
