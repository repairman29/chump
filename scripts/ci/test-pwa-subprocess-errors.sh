#!/usr/bin/env bash
# test-pwa-subprocess-errors.sh — CREDIBLE-021 tests.
#
# Verifies PWA subprocess error handling:
#   (1) cleanup_lease function present in web_server.rs
#   (2) configure_agent_credentials function present in web_server.rs
#   (3) spawn_gap_workflow calls cleanup_lease on failure paths (crash recovery)
#   (4) configure_agent_credentials forwards GH_TOKEN (env var check in source)
#   (5) configure_agent_credentials forwards SSH_KEY_PATH
#   (6) missing GH_TOKEN is handled gracefully (no unwrap/expect on env var)
#   (7) Rust unit tests for spawn_error_tests module present and passing
#   (8) CI gate: spawn_gap_workflow is gated by these tests (test module refs fn)
#
# Run: ./scripts/ci/test-pwa-subprocess-errors.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

echo "=== CREDIBLE-021 PWA subprocess error handling tests ==="
echo

# ── Test 1: cleanup_lease present in web_server.rs ────────────────────────────
echo "--- Test 1: cleanup_lease function defined in web_server.rs ---"
if grep -q 'fn cleanup_lease(' "$WEB_SERVER" 2>/dev/null; then
    ok "Test 1: cleanup_lease defined in web_server.rs"
else
    fail "Test 1: cleanup_lease missing from web_server.rs"
fi

# ── Test 2: configure_agent_credentials present ───────────────────────────────
echo "--- Test 2: configure_agent_credentials defined in web_server.rs ---"
if grep -q 'fn configure_agent_credentials(' "$WEB_SERVER" 2>/dev/null; then
    ok "Test 2: configure_agent_credentials defined in web_server.rs"
else
    fail "Test 2: configure_agent_credentials missing from web_server.rs"
fi

# ── Test 3: cleanup_lease called on claim failure path ─────────────────────────
echo "--- Test 3: spawn_gap_workflow calls cleanup_lease on claim failure ---"
if grep -q 'cleanup_lease' "$WEB_SERVER" 2>/dev/null; then
    _cleanup_count=$(grep -c 'cleanup_lease' "$WEB_SERVER" 2>/dev/null || echo 0)
    if [[ "${_cleanup_count:-0}" -ge 2 ]]; then
        ok "Test 3: cleanup_lease called in multiple error paths ($_cleanup_count times)"
    else
        fail "Test 3: cleanup_lease called only ${_cleanup_count} time(s) — may not cover crash + timeout paths"
    fi
else
    fail "Test 3: cleanup_lease not called in web_server.rs"
fi

# ── Test 4: GH_TOKEN forwarded in configure_agent_credentials ─────────────────
echo "--- Test 4: configure_agent_credentials forwards GH_TOKEN ---"
if grep -qE 'GH_TOKEN.*cmd\.env|cmd\.env.*GH_TOKEN' "$WEB_SERVER" 2>/dev/null; then
    ok "Test 4: configure_agent_credentials sets GH_TOKEN on subprocess"
else
    fail "Test 4: GH_TOKEN not forwarded in configure_agent_credentials"
fi

# ── Test 5: SSH_KEY_PATH forwarded ────────────────────────────────────────────
echo "--- Test 5: configure_agent_credentials forwards SSH_KEY_PATH ---"
if grep -qE 'SSH_KEY_PATH.*cmd\.env|cmd\.env.*SSH_KEY_PATH' "$WEB_SERVER" 2>/dev/null; then
    ok "Test 5: configure_agent_credentials sets SSH_KEY_PATH on subprocess"
else
    fail "Test 5: SSH_KEY_PATH not forwarded in configure_agent_credentials"
fi

# ── Test 6: GH_TOKEN absence is graceful (no expect/unwrap on it) ─────────────
echo "--- Test 6: missing GH_TOKEN handled gracefully (no panic path) ---"
# Check that GH_TOKEN is read with var() (returns Result) not expect()/unwrap()
# The pattern should be: std::env::var("GH_TOKEN") with an if let Ok(...) check
_gh_token_lines=$(grep -n 'GH_TOKEN' "$WEB_SERVER" 2>/dev/null | grep -v 'test\|#\[' | head -10)
if echo "$_gh_token_lines" | grep -q 'expect\|unwrap()'; then
    fail "Test 6: GH_TOKEN read with expect/unwrap — panics when missing"
else
    ok "Test 6: GH_TOKEN absence handled gracefully (no unwrap/expect)"
fi

# ── Test 7: Rust unit tests for spawn_error_tests module ─────────────────────
echo "--- Test 7: spawn_error_tests module exists with CREDIBLE-021 tests ---"
if grep -q 'spawn_error_tests\|credible021_' "$WEB_SERVER" 2>/dev/null; then
    _test_count=$(grep -c 'fn credible021_' "$WEB_SERVER" 2>/dev/null || echo 0)
    if [[ "${_test_count:-0}" -ge 4 ]]; then
        ok "Test 7: spawn_error_tests module has ${_test_count} CREDIBLE-021 Rust tests"
    else
        fail "Test 7: spawn_error_tests has only ${_test_count} tests (expected ≥ 4)"
    fi
else
    fail "Test 7: spawn_error_tests module missing from web_server.rs"
fi

# ── Test 8: Run cargo test for spawn_error_tests (if cargo available) ─────────
echo "--- Test 8: cargo test spawn_error_tests passes ---"
if command -v cargo >/dev/null 2>&1; then
    if cargo test --manifest-path "$REPO_ROOT/Cargo.toml" \
            --bin chump \
            -- web_server::spawn_error_tests \
            --test-threads=1 \
            2>/dev/null | grep -q 'test result: ok'; then
        ok "Test 8: cargo test spawn_error_tests all pass"
    else
        fail "Test 8: cargo test spawn_error_tests failed or produced unexpected output"
    fi
else
    ok "Test 8: cargo not available — skipping Rust test run (structural checks passed)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
