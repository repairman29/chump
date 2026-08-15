#!/usr/bin/env bash
# scripts/ci/test-gap-scoring.sh — INFRA-1816
#
# Validates the gap-value scorer vendored from repairman29/echeo
# (src/matchmaker.rs::calculate_ship_velocity_score), substrate for
# INFRA-1764 skill-aware routing:
#   1. src/gap_scoring.rs exists and exports the expected symbols
#   2. Vendoring lineage comment cites repairman29/echeo commit SHA (CP-005)
#   3. cargo unit tests pass: synthetic gap + routing_outcomes produce a
#      deterministic 0.0..=1.0 score (match, mismatch, clamp, determinism)
#   4. CP-005 cross-pollination brief exists

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1816 gap-value scorer tests ==="

SRC="$REPO_ROOT/src/gap_scoring.rs"

if [[ -f "$SRC" ]]; then
    ok "src/gap_scoring.rs exists"
else
    fail "src/gap_scoring.rs missing"
    echo ""
    echo "=== Summary: $PASS passed, $FAIL failed ==="
    exit 1
fi

for sym in "pub fn calculate_gap_value_score" "pub struct WorkerCapabilities" "pub struct RoutingOutcome"; do
    if grep -q "$sym" "$SRC"; then
        ok "exports $sym"
    else
        fail "missing $sym"
    fi
done

# Vendoring lineage (CP-005): must cite repairman29/echeo + original commit SHA.
if grep -q "repairman29/echeo" "$SRC" && grep -q "afbe64d6ddea1a89a486015eac1d9584b26d785f" "$SRC"; then
    ok "vendoring lineage cites repairman29/echeo commit SHA"
else
    fail "vendoring lineage comment missing repairman29/echeo commit SHA"
fi

if grep -q "calculate_ship_velocity_score" "$SRC"; then
    ok "cites original echeo function name (calculate_ship_velocity_score)"
else
    fail "missing citation of original echeo function name"
fi

# Module wired into the binary.
if grep -q "mod gap_scoring;" "$REPO_ROOT/src/main.rs"; then
    ok "gap_scoring wired into src/main.rs"
else
    fail "mod gap_scoring; missing from src/main.rs"
fi

# CP-005 cross-pollination brief.
CP005="$REPO_ROOT/docs/arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md"
if [[ -f "$CP005" ]]; then
    ok "CP-005 cross-pollination brief exists"
else
    fail "CP-005 cross-pollination brief missing"
fi

# ── Unit-test invocation (synthetic gap + routing_outcomes, deterministic) ──
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test --bin chump gap_scoring ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump gap_scoring --quiet -- --test-threads=1 2>&1 | tail -12); then
        ok "cargo test gap_scoring passed"
    else
        fail "cargo test gap_scoring failed"
    fi
else
    echo "  SKIP: cargo not on PATH — unit-test invocation skipped"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
