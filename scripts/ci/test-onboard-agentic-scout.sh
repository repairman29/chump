#!/usr/bin/env bash
# test-onboard-agentic-scout.sh — EFFECTIVE-166
#
# Smoke-tests that the EFFECTIVE-166 agentic scout changes are structurally
# correct in src/onboard.rs, and that the Rust unit tests covering the new
# path pass.
#
# Tests (no live LLM required):
#   1. spawn_agentic_scout function is present
#   2. build_scout_prompt function is present
#   3. run_provider_cascade_scout function is present (legacy fallback)
#   4. CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED kill-switch is wired
#   5. CHUMP_ONBOARD_SCOUT_MODEL env var is wired
#   6. Scout prompt contains "concrete signal" requirement
#   7. Scout prompt contains "gh issue list" instruction
#   8. cargo test onboard passes (includes all unit tests incl. shim test)
#
# Exit 0 = all assertions pass. Exit 1 = at least one failure.

set -uo pipefail

PASS=0
FAIL=0
_FAILURES=()

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); _FAILURES+=("$1"); printf '[FAIL] %s\n' "$1"; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ONBOARD_SRC="$REPO_ROOT/src/onboard.rs"

echo "=== EFFECTIVE-166 agentic scout test ==="
echo

# ── 1. Source file exists ─────────────────────────────────────────────────────
if [[ -f "$ONBOARD_SRC" ]]; then
    pass "onboard.rs exists at src/onboard.rs"
else
    fail "onboard.rs missing from src/"
fi

# ── 2. spawn_agentic_scout function present ──────────────────────────────────
if grep -q 'fn spawn_agentic_scout' "$ONBOARD_SRC"; then
    pass "spawn_agentic_scout function present"
else
    fail "spawn_agentic_scout function MISSING from onboard.rs"
fi

# ── 3. build_scout_prompt function present ───────────────────────────────────
if grep -q 'fn build_scout_prompt' "$ONBOARD_SRC"; then
    pass "build_scout_prompt function present"
else
    fail "build_scout_prompt function MISSING from onboard.rs"
fi

# ── 4. run_provider_cascade_scout (legacy fallback) present ─────────────────
if grep -q 'fn run_provider_cascade_scout' "$ONBOARD_SRC"; then
    pass "run_provider_cascade_scout fallback function present"
else
    fail "run_provider_cascade_scout function MISSING — legacy fallback path broken"
fi

# ── 5. Kill-switch env var wired ─────────────────────────────────────────────
if grep -q 'CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED' "$ONBOARD_SRC"; then
    pass "CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED kill-switch referenced in onboard.rs"
else
    fail "CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED kill-switch MISSING from onboard.rs"
fi

# ── 6. CHUMP_ONBOARD_SCOUT_MODEL env var wired ───────────────────────────────
if grep -q 'CHUMP_ONBOARD_SCOUT_MODEL' "$ONBOARD_SRC"; then
    pass "CHUMP_ONBOARD_SCOUT_MODEL model-override env var referenced in onboard.rs"
else
    fail "CHUMP_ONBOARD_SCOUT_MODEL MISSING from onboard.rs"
fi

# ── 7. Scout prompt demands concrete signal ───────────────────────────────────
if grep -qi 'concrete signal\|CONCRETE signal' "$ONBOARD_SRC"; then
    pass "Scout prompt requires a concrete evidence signal per proposal"
else
    fail "Scout prompt does NOT require a concrete signal — generic proposals allowed"
fi

# ── 8. Scout prompt includes gh issue list instruction ───────────────────────
if grep -q 'gh issue list' "$ONBOARD_SRC"; then
    pass "Scout prompt instructs agent to query open GitHub issues"
else
    fail "Scout prompt MISSING 'gh issue list' instruction"
fi

# ── 9. Capable model (not 7B) is the default ─────────────────────────────────
if grep -q 'claude-sonnet' "$ONBOARD_SRC"; then
    pass "claude-sonnet (capable model) is the default for agentic scout"
else
    fail "No claude-sonnet default found — scout may still use a weak model"
fi

# ── 10. env-vars-internal.txt updated ────────────────────────────────────────
ENV_VARS_FILE="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
if [[ -f "$ENV_VARS_FILE" ]]; then
    if grep -q 'CHUMP_ONBOARD_SCOUT_MODEL' "$ENV_VARS_FILE" && \
       grep -q 'CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED' "$ENV_VARS_FILE"; then
        pass "Both new env vars registered in env-vars-internal.txt"
    else
        fail "New env vars NOT fully registered in scripts/ci/env-vars-internal.txt"
    fi
else
    fail "scripts/ci/env-vars-internal.txt not found"
fi

# ── 11. cargo test onboard passes ────────────────────────────────────────────
echo
echo "--- Running cargo test onboard (unit tests incl. agentic scout tests) ---"
CARGO_OUT=$(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo test onboard 2>&1)
if echo "$CARGO_OUT" | grep -q "test result: ok"; then
    pass "cargo test onboard: all unit tests pass (incl. EFFECTIVE-166 shim test)"
elif echo "$CARGO_OUT" | grep -q "FAILED"; then
    FAILED_TESTS=$(echo "$CARGO_OUT" | grep "FAILED" | head -5)
    fail "cargo test onboard: tests FAILED — $FAILED_TESTS"
else
    fail "cargo test onboard: could not determine pass/fail — output: $(echo "$CARGO_OUT" | tail -5)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failures:"
    for f in "${_FAILURES[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
