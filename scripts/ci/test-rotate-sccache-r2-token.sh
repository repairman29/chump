#!/usr/bin/env bash
# scripts/ci/test-rotate-sccache-r2-token.sh — INFRA-2237 smoke
#
# Tests the rotate-sccache-r2-token.sh script's error paths + dry-run mode.
# Does NOT make real CF or GH API calls — uses unset env vars + --dry-run to
# exercise the validation + argument parsing surfaces.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROT="$REPO_ROOT/scripts/ops/rotate-sccache-r2-token.sh"

PASS=0
FAIL=0
_pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
_fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== test-rotate-sccache-r2-token.sh (INFRA-2237) ==="

# ── Test 1: bash -n syntax ──────────────────────────────────────────────────
if bash -n "$ROT" 2>&1; then
    _pass "syntax: rotate-sccache-r2-token.sh passes bash -n"
else
    _fail "syntax: rotate-sccache-r2-token.sh has bash syntax errors"
fi

# ── Test 2: --help exits 0 + shows usage ────────────────────────────────────
if bash "$ROT" --help 2>&1 | grep -q "Atomically rotate"; then
    _pass "help: --help prints docstring"
else
    _fail "help: --help did not print expected docstring"
fi

# ── Test 3: unknown flag errors with usage ──────────────────────────────────
out="$(bash "$ROT" --bogus-flag 2>&1 || true)"
if echo "$out" | grep -q "unknown flag"; then
    _pass "args: --bogus-flag rejected with 'unknown flag' message"
else
    _fail "args: --bogus-flag did NOT produce unknown-flag error"
fi

# ── Test 4: missing CHUMP_CF_API_TOKEN refuses with operator message ────────
out="$(env -u CHUMP_CF_API_TOKEN -u CHUMP_R2_ACCOUNT_ID bash "$ROT" --dry-run 2>&1 || true)"
if echo "$out" | grep -q "CHUMP_CF_API_TOKEN env var is required"; then
    _pass "validation: missing CHUMP_CF_API_TOKEN refused with operator message"
else
    _fail "validation: missing CHUMP_CF_API_TOKEN did NOT produce expected error"
    echo "  got: $out" | head -3 >&2
fi

# ── Test 5: missing CHUMP_R2_ACCOUNT_ID refuses with operator message ───────
out="$(CHUMP_CF_API_TOKEN=test env -u CHUMP_R2_ACCOUNT_ID bash "$ROT" --dry-run 2>&1 || true)"
if echo "$out" | grep -q "CHUMP_R2_ACCOUNT_ID env var is required"; then
    _pass "validation: missing CHUMP_R2_ACCOUNT_ID refused with operator message"
else
    _fail "validation: missing CHUMP_R2_ACCOUNT_ID did NOT produce expected error"
fi

# ── Test 6: default is dry-run when --execute not passed (no real calls) ────
# We can't fully exercise dry-run without hitting CF (the validation step
# pings CF). But we can verify the parse loop defaults EXECUTE=0 by
# inspecting the script source.
if grep -q '^EXECUTE=0$' "$ROT"; then
    _pass "default: EXECUTE defaults to 0 (dry-run); --execute required to rotate"
else
    _fail "default: EXECUTE does NOT default to 0 — could rotate without --execute"
fi

# ── Test 7: audit fingerprint helper never prints full secret ──────────────
# _finger() should output first-4...last-4, not the full string.
src="$(grep -A 9 '^_finger() {' "$ROT")"
if echo "$src" | grep -q 's:0:4' && echo "$src" | grep -q 's: -4'; then
    _pass "audit: _finger() uses first-4/last-4 pattern (never logs full secret)"
else
    _fail "audit: _finger() does NOT use first-4/last-4 pattern"
fi

# ── Test 8: ambient emit kind is registered ─────────────────────────────────
if grep -q "sccache_r2_token_rotated" "$ROT" \
   && grep -q "sccache_r2_token_rotation_failed" "$ROT" \
   && grep -q "sccache_r2_token_rotation_partial" "$ROT"; then
    _pass "ambient: emits sccache_r2_token_rotated + _failed + _partial kinds"
else
    _fail "ambient: missing one or more expected ambient kinds"
fi

# ── Test 9: trap restores on partial failure ────────────────────────────────
if grep -q 'trap _cleanup_on_fail EXIT INT TERM' "$ROT"; then
    _pass "atomic: trap EXIT/INT/TERM is wired to _cleanup_on_fail"
else
    _fail "atomic: trap is NOT wired — orphan-new-token risk on mid-flow failure"
fi

# ── Test 10: documentation cross-reference ──────────────────────────────────
if grep -q "INFRA-2237" "$ROT"; then
    _pass "doc: INFRA-2237 attribution present in script header"
else
    _fail "doc: INFRA-2237 attribution missing"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
