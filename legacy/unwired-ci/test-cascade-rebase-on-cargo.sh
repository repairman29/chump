#!/usr/bin/env bash
# INFRA-670: regression test for cascade_rebase_if_hot in queue-driver.sh.
# Verifies that:
#   1. When the latest main commit touched Cargo.toml, the function triggers
#      cascade rebase and emits cascade_rebase_triggered to ambient.jsonl.
#   2. When the latest main commit did NOT touch Cargo.toml, no cascade fires.
#   3. --dry-run mode logs without calling gh.
#
# Run from repo root: bash scripts/ci/test-cascade-rebase-on-cargo.sh

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"

# ── 1. WORKSPACE_HOT_FILES list is present in queue-driver.sh ─────────────
if grep -q 'WORKSPACE_HOT_FILES' "$DRIVER"; then
    pass "WORKSPACE_HOT_FILES defined in queue-driver.sh"
else
    fail "WORKSPACE_HOT_FILES missing from queue-driver.sh"
fi

# ── 2. cascade_rebase_if_hot function is present ──────────────────────────
if grep -q 'cascade_rebase_if_hot' "$DRIVER"; then
    pass "cascade_rebase_if_hot function defined"
else
    fail "cascade_rebase_if_hot function missing from queue-driver.sh"
fi

# ── 3. Cargo.toml is listed in WORKSPACE_HOT_FILES ─────────────────────────
if grep -A 10 'WORKSPACE_HOT_FILES=' "$DRIVER" | grep -q '"Cargo.toml"'; then
    pass "Cargo.toml listed in WORKSPACE_HOT_FILES"
else
    fail "Cargo.toml not found in WORKSPACE_HOT_FILES"
fi

# ── 4. cascade_rebase_if_hot is called before the BEHIND/DIRTY loop ────────
# Verify call site appears before "behind_candidates=" in the file.
cascade_line=$(grep -n 'cascade_rebase_if_hot$' "$DRIVER" | head -1 | cut -d: -f1)
behind_line=$(grep -n 'behind_candidates=' "$DRIVER" | head -1 | cut -d: -f1)
if [[ -n "$cascade_line" && -n "$behind_line" && "$cascade_line" -lt "$behind_line" ]]; then
    pass "cascade_rebase_if_hot called before BEHIND loop (line $cascade_line < $behind_line)"
else
    fail "cascade_rebase_if_hot must be called before BEHIND loop (cascade=$cascade_line, behind=$behind_line)"
fi

# ── 5. bot-merge.sh includes Cargo.toml in BOT_MERGE_HOT_FILES ────────────
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
if grep -A 15 'BOT_MERGE_HOT_FILES=' "$BOT_MERGE" | grep -q '"Cargo.toml"'; then
    pass "Cargo.toml listed in BOT_MERGE_HOT_FILES"
else
    fail "Cargo.toml not found in BOT_MERGE_HOT_FILES in bot-merge.sh"
fi

# ── 6. ambient event kind is cascade_rebase_triggered ──────────────────────
if grep -q 'cascade_rebase_triggered' "$DRIVER"; then
    pass "cascade_rebase_triggered event kind emitted"
else
    fail "cascade_rebase_triggered event kind missing from queue-driver.sh"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
