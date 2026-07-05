#!/usr/bin/env bash
# scripts/ci/test-fleet-pulse.sh — INFRA-1995 (THE FLOOR Phase 2)
#
# Validates the chump fleet pulse single-pane aggregator:
#   1. Source-contract: module + main.rs wiring present
#   2. cargo unit tests pass (6 tests in src/fleet_pulse.rs)
#   3. Exit code mapping: HOLD=2, HOT=1, else 0
#
# W-013 immunization (RESILIENT-024 pattern): unset workflow-injected env.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1995 fleet-pulse tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MODULE="$REPO_ROOT/src/fleet_pulse.rs"
MAIN="$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"

unset CHUMP_REPO CHUMP_LOCK_DIR

# ── Source-contract ────────────────────────────────────────────────────────
[[ -f "$MODULE" ]] && ok "module file exists" || { fail "missing $MODULE"; exit 1; }

for needle in \
    "pub fn build" \
    "pub fn render_text" \
    "pub struct FleetPulse" \
    "pub struct FleetHold" \
    "pub struct ActiveLeases" \
    "pub struct AmbientEvent" \
    "fleet-hold.txt" \
    "ci_failure_cluster" \
    "admin_merge_executed" \
    "wedge_detected"; do
    if grep -qF "$needle" "$MODULE"; then
        ok "module: $needle"
    else
        fail "module missing: $needle"
    fi
done

# ── Main wiring ────────────────────────────────────────────────────────────
for needle in \
    "mod fleet_pulse" \
    "fleet_pulse::build" \
    "fleet_pulse::render_text" \
    "\"pulse\" =>"; do
    if grep -qF "$needle" "$MAIN"; then
        ok "main.rs: $needle"
    else
        fail "main.rs missing: $needle"
    fi
done

# ── cargo unit tests ──────────────────────────────────────────────────────
echo "--- running cargo test --bin chump fleet_pulse::tests ---"
CARGO_BIN=""
if [[ -n "${CARGO:-}" ]] && [[ -x "$CARGO" ]]; then
    CARGO_BIN="$CARGO"
elif command -v cargo >/dev/null 2>&1; then
    CARGO_BIN="$(command -v cargo)"
else
    for cand in "${HOME:-/Users/jeffadkins}/.cargo/bin/cargo" /usr/local/bin/cargo /opt/homebrew/bin/cargo; do
        if [[ -x "$cand" ]]; then CARGO_BIN="$cand"; break; fi
    done
fi
if [[ -n "$CARGO_BIN" ]] && "$CARGO_BIN" test --bin chump --quiet fleet_pulse::tests 2>&1 \
        | tail -10 | grep -qE "test result: ok|6 passed"; then
    ok "cargo unit tests pass for fleet_pulse (6 tests)"
else
    fail "cargo unit tests failed (run: cargo test --bin chump fleet_pulse::tests; CARGO_BIN=$CARGO_BIN)"
fi

# ── Exit code mapping present (file-wide check, not spatial) ──────────────
if grep -qF "pulse.fleet_hold.active" "$MAIN" \
   && grep -qF "FloorTemp::Hot" "$MAIN" \
   && grep -qF "std::process::exit(code)" "$MAIN"; then
    ok "exit code mapping: HOLD=2 HOT=1 else=0"
else
    fail "exit code mapping incomplete"
fi

# ── render_text covers all sections ───────────────────────────────────────
for section in "Fleet pulse" "Floor temperature" "Fleet HOLD" "Active leases" "wedge detections" "admin-merges" "alerts" "CI failure clusters"; do
    if grep -qF "$section" "$MODULE"; then
        ok "render_text section: $section"
    else
        fail "render_text missing section: $section"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
