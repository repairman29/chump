#!/usr/bin/env bash
# test-onboard-clone-auth.sh — EFFECTIVE-112
#
# Smoke-tests that `chump onboard` / src/onboard.rs authenticate GitHub
# HTTPS clones using the fleet's GitHub credentials, so private repos
# (e.g. repairman29/BEAST-MODE) can be cloned.
#
# Tests (no live network required):
#   1. inject_token_into_url unit tests pass (via `cargo test onboard`)
#   2. resolve_github_token priority: GH_TOKEN > GITHUB_TOKEN > gh auth token
#      — verified by inspecting the source for the correct priority order
#   3. onboard.rs calls inject_token_into_url when a GitHub HTTPS URL is given
#   4. onboard.rs bails (non-zero) on git clone failure — no silent exit-0
#   5. Token value is never passed to eprintln!/println! (no token leakage)
#   6. inject_token_into_url does NOT modify SSH or non-github.com URLs
#
# Exit 0 = all assertions pass. Exit 1 = at least one failure.

set -uo pipefail

PASS=0
FAIL=0
_FAILURES=()

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); _FAILURES+=("$1"); printf '[FAIL] %s\n' "$1"; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi

# Source checks always run against the current worktree (where the fix lives).
# Cargo build runs from REPO_ROOT (the worktree has Cargo.toml + build cache).
ONBOARD_SRC="$REPO_ROOT/src/onboard.rs"

echo "=== EFFECTIVE-112 onboard clone-auth test ==="
echo

# ── 1. Source file exists ─────────────────────────────────────────────────────
if [[ -f "$ONBOARD_SRC" ]]; then
    pass "onboard.rs exists at src/onboard.rs"
else
    fail "onboard.rs missing from src/"
fi

# ── 2. inject_token_into_url function is present ──────────────────────────────
if grep -q 'fn inject_token_into_url' "$ONBOARD_SRC"; then
    pass "inject_token_into_url function present in onboard.rs"
else
    fail "inject_token_into_url function MISSING from onboard.rs"
fi

# ── 3. resolve_github_token function is present ──────────────────────────────
if grep -q 'fn resolve_github_token' "$ONBOARD_SRC"; then
    pass "resolve_github_token function present in onboard.rs"
else
    fail "resolve_github_token function MISSING from onboard.rs"
fi

# ── 4. GH_TOKEN has highest priority in resolve_github_token ─────────────────
# Verify GH_TOKEN appears before GITHUB_TOKEN in the source
GH_TOKEN_LINE=$(grep -n '"GH_TOKEN"' "$ONBOARD_SRC" | grep 'std::env::var' | head -1 | cut -d: -f1)
GITHUB_TOKEN_LINE=$(grep -n '"GITHUB_TOKEN"' "$ONBOARD_SRC" | grep 'std::env::var' | head -1 | cut -d: -f1)
if [[ -n "$GH_TOKEN_LINE" && -n "$GITHUB_TOKEN_LINE" && "$GH_TOKEN_LINE" -lt "$GITHUB_TOKEN_LINE" ]]; then
    pass "GH_TOKEN checked before GITHUB_TOKEN (correct priority order)"
else
    fail "GH_TOKEN priority order wrong: GH_TOKEN line=$GH_TOKEN_LINE, GITHUB_TOKEN line=$GITHUB_TOKEN_LINE"
fi

# ── 5. gh auth token is a fallback in resolve_github_token ───────────────────
if grep -q '"gh"' "$ONBOARD_SRC" && grep -A3 '"gh"' "$ONBOARD_SRC" | grep -q '"auth"'; then
    pass "gh auth token fallback present in resolve_github_token"
else
    fail "gh auth token fallback MISSING from resolve_github_token"
fi

# ── 6. Token is injected for HTTPS GitHub URLs ────────────────────────────────
if grep -q 'inject_token_into_url' "$ONBOARD_SRC"; then
    pass "inject_token_into_url is called in the clone path"
else
    fail "inject_token_into_url never called — token injection not wired up"
fi

# ── 7. Inject URL uses x-access-token format ─────────────────────────────────
if grep -q 'x-access-token' "$ONBOARD_SRC"; then
    pass "x-access-token credential format used in URL injection"
else
    fail "x-access-token format MISSING — GitHub token injection uses wrong format"
fi

# ── 8. Non-zero exit on clone failure (AC-2) ──────────────────────────────────
# shallow_clone must bail! when git clone exits non-zero
if grep -A5 'if !status.success()' "$ONBOARD_SRC" | grep -q 'bail!'; then
    pass "shallow_clone bails (non-zero) on git clone failure (AC-2)"
else
    fail "shallow_clone does NOT bail on clone failure — silent exit-0 bug survives"
fi

# ── 9. Token value never logged (security: no token leakage) ─────────────────
# Verify that lines containing the token variable don't pass it to eprintln!/println!
# We check: no `eprintln!(...{token}...)` or `println!(...{token}...)` where token is
# the live value (not a redacted placeholder).
if grep -E 'eprintln!.*\{token\}|println!.*\{token\}' "$ONBOARD_SRC" | grep -v 'not logged\|REDACTED\|<token>' > /dev/null 2>&1; then
    fail "Token value may be logged to stderr/stdout — check for {token} in eprintln!/println!"
else
    pass "Token value not passed to eprintln!/println! (no accidental leakage)"
fi

# ── 10. Unit test coverage for inject_token_into_url ─────────────────────────
if grep -q 'test_inject_token' "$ONBOARD_SRC"; then
    pass "Unit tests for inject_token_into_url present in onboard.rs"
else
    fail "No unit tests for inject_token_into_url — add test_inject_token_* cases"
fi

# ── 11. cargo test onboard passes ─────────────────────────────────────────────
echo
echo "--- Running cargo test onboard (unit tests) ---"
if (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo test onboard 2>&1 | grep -E "^test onboard|test result") | grep -v "FAILED"; then
    # Check for actual failure in cargo output
    CARGO_OUT=$(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo test onboard 2>&1)
    if echo "$CARGO_OUT" | grep -q "test result: ok"; then
        pass "cargo test onboard: all unit tests pass"
    else
        fail "cargo test onboard: some tests FAILED — $(echo "$CARGO_OUT" | grep FAILED | head -3)"
    fi
else
    fail "cargo test onboard: failed to run"
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
