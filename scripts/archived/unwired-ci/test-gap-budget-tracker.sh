#!/usr/bin/env bash
# scripts/ci/test-gap-budget-tracker.sh — INFRA-1486
#
# Verifies the per-gap budget tracker (Marcus trust gate):
#   1. tier_default_cost_usd returns correct ceilings per effort tier
#   2. File-touch budget breaches cleanly at max
#   3. Dep-add with default ceiling 0 breaches on first add
#   4. LLM cost breach emits ambient event
#   5. Bypass env (CHUMP_BUDGET_ENFORCE=0) short-circuits all checks
#   6. Threshold events are idempotent (warn/breach fire once per dim)
#
# Strategy: run the cargo unit-tests for the module (logic) + a source-
# contract check (event kinds registered) + structural assertions.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1486 per-gap budget tracker tests ==="

# ── Source-contract checks ────────────────────────────────────────────────────
SRC="$REPO_ROOT/src/budget_tracker.rs"

if [[ -f "$SRC" ]]; then
    ok "src/budget_tracker.rs exists"
else
    fail "src/budget_tracker.rs missing"
    echo ""
    echo "=== Summary: $PASS passed, $FAIL failed ==="
    exit 1
fi

for sym in "pub fn tier_default_cost_usd" "pub struct Budget" "pub enum BudgetAction" "pub struct BudgetTracker" "fn record_file_touch" "fn record_dep_add" "fn record_llm_cost"; do
    if grep -q "$sym" "$SRC"; then
        ok "exports $sym"
    else
        fail "missing $sym"
    fi
done

for kind in "gap_budget_warn" "gap_budget_breach"; do
    if grep -q "kind: $kind" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
        ok "EVENT_REGISTRY.yaml registers $kind"
    else
        fail "EVENT_REGISTRY.yaml missing kind $kind"
    fi
done

# Bypass env honored
if grep -q 'CHUMP_BUDGET_ENFORCE.*"0"' "$SRC"; then
    ok "CHUMP_BUDGET_ENFORCE=0 bypass implemented"
else
    fail "CHUMP_BUDGET_ENFORCE bypass missing"
fi

# ── Unit-test invocation ──────────────────────────────────────────────────────
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test budget_tracker ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump budget_tracker --quiet -- --test-threads=1 2>&1 | tail -8); then
        ok "cargo test budget_tracker passed"
    else
        fail "cargo test budget_tracker failed"
    fi
else
    echo "  SKIP: cargo not on PATH — unit-test invocation skipped"
fi

# ── Behavioural integration (the synthetic 11-file-touch scenario) ───────────
# We exercise the tracker via a tiny Rust harness embedded in cargo test.
# The unit tests above already cover this (file_touch_breach_at_max), so
# this section is a structural redundancy assertion only — we want the
# Marcus-named scenario (11 modifications) explicitly named in the test
# suite.
if grep -q "max_file_touches: 10" "$SRC"; then
    ok "default max_file_touches=10 (Marcus 14-file threshold prevention)"
else
    fail "max_file_touches default not set to 10"
fi

if grep -q "max_dep_adds: 0" "$SRC"; then
    ok "default max_dep_adds=0 (Marcus 'three brand-new dependencies' prevention)"
else
    fail "max_dep_adds default not set to 0"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
