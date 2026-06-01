#!/usr/bin/env bash
# scripts/ci/test-cascade-graceful-skip.sh — INFRA-2372 smoke test
#
# Verifies that `should_cascade_on_error_string` (in src/provider_cascade.rs)
# now classifies the Gemini "Function calling config is set without
# function_declarations" 400 — and related malformed-tool-config 400s — as
# cascade-able. Prior to this fix, a single malformed cascade slot would
# 400 the whole call (bare `chump` invocation surface).
#
# Runs as a `cargo test` invocation against the specific unit tests added
# in provider_cascade.rs#[cfg(test)]. Keeps the test cheap (<5s warm) by
# scoping to the three relevant test fns.
#
# Run locally:
#   scripts/ci/test-cascade-graceful-skip.sh
#
# Exit codes: 0 = pass; 1 = test failed; 2 = build failed.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Run the targeted cascade-graceful-skip tests added for INFRA-2372.
# These tests are pure-function (no env, no network) so they run fast.
TESTS=(
  "should_cascade_on_gemini_function_calling_config_400"
  "should_cascade_on_gemini_function_declarations_missing"
  "should_not_cascade_on_generic_bad_request"
)

ok=0
for t in "${TESTS[@]}"; do
  if cargo test -p chump --bin chump --quiet -- --exact "provider_cascade::tests::$t" 2>&1 | tail -10 | grep -qE "test result: ok\."; then
    echo "  PASS: $t"
    ok=$((ok + 1))
  else
    echo "  FAIL: $t"
    cargo test -p chump --lib -- --exact "provider_cascade::tests::$t" 2>&1 | tail -30
    exit 1
  fi
done

if [[ $ok -ne ${#TESTS[@]} ]]; then
  echo "FAIL: expected ${#TESTS[@]} tests pass, got $ok"
  exit 1
fi

echo "PASS: cascade graceful-skip predicates (INFRA-2372) — $ok tests"
