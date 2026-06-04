#!/usr/bin/env bash
# test-onboard-clone-auth.sh — EFFECTIVE-112 + EFFECTIVE-123
#
# Smoke-tests that `chump onboard` / src/onboard.rs authenticate GitHub
# HTTPS clones so private repos (e.g. repairman29/BEAST-MODE) can be cloned.
#
# EFFECTIVE-112 (clone-auth):
#   - inject_token_into_url builds an x-access-token URL for github.com HTTPS
#   - onboard bails (non-zero) on clone failure — no silent exit-0
#   - the token value is never logged
#
# EFFECTIVE-123 (validate-and-fall-through + keyring):
#   - explicit env tokens are *validated*; a set-but-invalid $GITHUB_TOKEN
#     falls through instead of failing the clone (the BEAST-MODE bug)
#   - GH_TOKEN is tried before GITHUB_TOKEN
#   - the keyring path uses `gh repo clone` with GH_TOKEN/GITHUB_TOKEN stripped
#     (a keyring/OAuth token can't be re-injected as a bearer)
#
# Source-inspection + `cargo test onboard` only — no live network required.
# Exit 0 = all assertions pass. Exit 1 = at least one failure.

set -uo pipefail

PASS=0
FAIL=0
_FAILURES=()

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); _FAILURES+=("$1"); printf '[FAIL] %s\n' "$1"; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ONBOARD_SRC="$REPO_ROOT/src/onboard.rs"

echo "=== EFFECTIVE-112 + EFFECTIVE-123 onboard clone-auth test ==="
echo

# ── 1. Source file exists ─────────────────────────────────────────────────────
if [[ -f "$ONBOARD_SRC" ]]; then
    pass "onboard.rs exists at src/onboard.rs"
else
    fail "onboard.rs missing from src/"
    echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

# ── 2. inject_token_into_url present (tier-1 explicit-token clone) ────────────
if grep -q 'fn inject_token_into_url' "$ONBOARD_SRC"; then
    pass "inject_token_into_url function present"
else
    fail "inject_token_into_url function MISSING"
fi

# ── 3. resolve_valid_env_token present (EFFECTIVE-123 env resolver) ───────────
if grep -q 'fn resolve_valid_env_token' "$ONBOARD_SRC"; then
    pass "resolve_valid_env_token function present"
else
    fail "resolve_valid_env_token function MISSING (EFFECTIVE-123)"
fi

# ── 4. GH_TOKEN tried before GITHUB_TOKEN (priority order, by byte offset) ────
GH_POS=$(grep -abo '"GH_TOKEN"' "$ONBOARD_SRC" | head -1 | cut -d: -f1)
GITHUB_POS=$(grep -abo '"GITHUB_TOKEN"' "$ONBOARD_SRC" | head -1 | cut -d: -f1)
if [[ -n "$GH_POS" && -n "$GITHUB_POS" && "$GH_POS" -lt "$GITHUB_POS" ]]; then
    pass "GH_TOKEN literal precedes GITHUB_TOKEN literal (correct priority)"
else
    fail "GH_TOKEN priority wrong: GH_TOKEN@$GH_POS, GITHUB_TOKEN@$GITHUB_POS"
fi

# ── 5. validate-and-fall-through core present (EFFECTIVE-123) ─────────────────
if grep -q 'fn first_valid_token' "$ONBOARD_SRC" && grep -q 'fn validate_github_token' "$ONBOARD_SRC"; then
    pass "first_valid_token + validate_github_token present (validate-and-fall-through)"
else
    fail "validate-and-fall-through core MISSING (first_valid_token/validate_github_token)"
fi

# ── 6. gh repo clone keyring fallback present + env stripped ──────────────────
if grep -q 'fn gh_repo_clone' "$ONBOARD_SRC" \
   && grep -A12 'fn gh_repo_clone' "$ONBOARD_SRC" | grep -q 'env_remove("GH_TOKEN")' \
   && grep -A12 'fn gh_repo_clone' "$ONBOARD_SRC" | grep -q '"clone"'; then
    pass "gh_repo_clone keyring fallback present with stale-env strip (EFFECTIVE-123)"
else
    fail "gh_repo_clone keyring fallback MISSING or doesn't strip GH_TOKEN/GITHUB_TOKEN"
fi

# ── 7. Inject URL uses x-access-token format ──────────────────────────────────
if grep -q 'x-access-token' "$ONBOARD_SRC"; then
    pass "x-access-token credential format used in URL injection"
else
    fail "x-access-token format MISSING"
fi

# ── 8. Non-zero exit on clone failure (AC-2: no silent exit-0) ────────────────
# run_git_clone must bail! when git clone exits non-zero.
if grep -A6 'if !status.success()' "$ONBOARD_SRC" | grep -q 'bail!'; then
    pass "clone helpers bail (non-zero) on clone failure (AC-2)"
else
    fail "clone failure NOT surfaced — silent exit-0 bug could survive"
fi

# ── 9. Token value never logged (no token leakage) ───────────────────────────
if grep -E 'eprintln!.*\{token\}|println!.*\{token\}' "$ONBOARD_SRC" | grep -v 'not logged\|REDACTED\|<token>' > /dev/null 2>&1; then
    fail "Token value may be logged — {token} found in eprintln!/println!"
else
    pass "Token value not passed to eprintln!/println! (no leakage)"
fi

# ── 10. EFFECTIVE-123 fall-through unit test present ──────────────────────────
if grep -q 'fn test_first_valid_token_falls_through_invalid_to_valid' "$ONBOARD_SRC"; then
    pass "invalid-first-token → valid-fallback unit test present (EFFECTIVE-123 AC-3)"
else
    fail "EFFECTIVE-123 fall-through unit test MISSING"
fi

# ── 11. inject_token unit tests present ───────────────────────────────────────
if grep -q 'test_inject_token' "$ONBOARD_SRC"; then
    pass "inject_token_into_url unit tests present"
else
    fail "No unit tests for inject_token_into_url"
fi

# ── 12. cargo test onboard passes ─────────────────────────────────────────────
echo
echo "--- Running cargo test onboard (unit tests) ---"
CARGO_OUT=$(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo test --bin chump onboard 2>&1)
if echo "$CARGO_OUT" | grep -q "test result: ok"; then
    pass "cargo test onboard: all unit tests pass"
else
    fail "cargo test onboard FAILED: $(echo "$CARGO_OUT" | grep -E 'FAILED|error' | head -3)"
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
