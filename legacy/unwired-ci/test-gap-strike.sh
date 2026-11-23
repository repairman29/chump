#!/usr/bin/env bash
# test-gap-strike.sh — EFFECTIVE-310
#
# Validates the failure→decompose reflex plumbing:
#  - `chump gap strike` arm wired in main.rs
#  - gap_strikes store methods present in chump-gap-store
#  - worker.sh calls the reflex on both failure paths and gates INFRA-267
#  - clean-cycle strike reset present
#  - gap_auto_decomposed registered in EVENT_REGISTRY.yaml

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== EFFECTIVE-310 gap strike / decompose reflex test ==="
echo

# 1. Subcommand wired in main.rs.
if grep -q '"strike"' "$REPO_ROOT/src/main.rs"; then
    ok "strike arm in main.rs"
else
    fail "strike arm missing from main.rs"
fi

# 2. Threshold env respected + exit code 10 contract.
if grep -q 'CHUMP_DECOMPOSE_STRIKE_THRESHOLD' "$REPO_ROOT/src/main.rs" \
   && grep -A 40 '"strike" =>' "$REPO_ROOT/src/main.rs" | grep -q 'exit(10)'; then
    ok "threshold env + exit(10) contract in strike arm"
else
    fail "strike arm missing threshold env or exit(10)"
fi

# 3. Store methods in chump-gap-store.
STORE="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"
for m in record_strike strike_count clear_strikes; do
    if grep -q "pub fn $m" "$STORE"; then
        ok "store method $m"
    else
        fail "store method $m missing"
    fi
done
if grep -q 'gap_strikes' "$STORE"; then
    ok "gap_strikes table in store"
else
    fail "gap_strikes table missing from store"
fi

# 4. worker.sh reflex: called on hard-failure AND timeout paths.
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
n_calls=$(grep -c '_effective_003_reflex$' "$WORKER" || true)
if [ "$n_calls" -ge 2 ]; then
    ok "reflex invoked on >=2 failure paths ($n_calls calls)"
else
    fail "reflex invoked on <2 failure paths ($n_calls calls)"
fi

# 5. INFRA-267 P0 fallback gated on _decomposed_this_cycle.
if grep -q '_decomposed_this_cycle" -eq 0' "$WORKER"; then
    ok "INFRA-267 fallback gated on decompose flag"
else
    fail "INFRA-267 fallback not gated on decompose flag"
fi

# 6. Clean cycle resets strikes.
if grep -q 'gap strike "\$GAP_ID" --reset' "$WORKER"; then
    ok "clean-cycle strike reset present"
else
    fail "clean-cycle strike reset missing"
fi

# 7. Decompose call strips OPENAI_* (frontier plans, open models execute).
if grep -q 'env -u OPENAI_API_BASE -u OPENAI_MODEL' "$WORKER"; then
    ok "frontier decompose strips OPENAI_* env"
else
    fail "decompose call does not strip OPENAI_* env"
fi

# 8. Event registered.
if grep -q 'kind: gap_auto_decomposed' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "gap_auto_decomposed in EVENT_REGISTRY.yaml"
else
    fail "gap_auto_decomposed missing from EVENT_REGISTRY.yaml"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
