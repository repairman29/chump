#!/usr/bin/env bash
# INFRA-2165: smoke tests for chump --briefing umbrella-context injection.
#
# Tests:
#   1. Unit tests for src/briefing.rs (cargo test --bin chump briefing)
#   2. Smoke: chump --briefing INFRA-2130 output contains META-124 umbrella context
#      after INFRA-2165 ships (best-effort; skipped when INFRA-2130 or META-124
#      not found in state.db so the test doesn't fail on fresh repos).
#
# Exit 0 on pass, non-zero on failure.
set -euo pipefail
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "[test-briefing] running unit tests..."
PATH="$HOME/.cargo/bin:$PATH" cargo test --bin chump briefing 2>&1 | tail -5
echo "[test-briefing] unit tests passed."

# Smoke test: run --briefing INFRA-2130 and check for META-124 umbrella context.
echo "[test-briefing] smoke: chump --briefing INFRA-2130..."
BRIEFING_OUT="$(chump --briefing INFRA-2130 2>&1)" || true

if echo "$BRIEFING_OUT" | grep -q "Gap not found"; then
    echo "[test-briefing] smoke: INFRA-2130 not in state.db — skip umbrella check (fresh repo)"
    exit 0
fi

if echo "$BRIEFING_OUT" | grep -q "META-124"; then
    echo "[test-briefing] smoke: META-124 umbrella context present in INFRA-2130 briefing. PASS."
else
    echo "[test-briefing] smoke: META-124 umbrella context MISSING from INFRA-2130 briefing."
    echo "--- briefing output ---"
    echo "$BRIEFING_OUT" | head -40
    echo "--- end ---"
    exit 1
fi

echo "[test-briefing] all checks passed."
