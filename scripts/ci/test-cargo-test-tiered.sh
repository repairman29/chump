#!/usr/bin/env bash
# test-cargo-test-tiered.sh — INFRA-1380
#
# Asserts that:
#   1. cargo-test-fast job exists in ci.yml
#   2. cargo-test-slow job exists in ci.yml
#   3. cargo-test-slow.needs includes cargo-test-fast
#   4. cargo-test-required.needs includes both cargo-test-fast and cargo-test-slow
#
# Usage: bash scripts/ci/test-cargo-test-tiered.sh
# Exit 0 on pass, 1 on any assertion failure.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; ((PASS++)) || true; }
fail() { echo "  FAIL: $*" >&2; ((FAIL++)) || true; }

echo "=== test-cargo-test-tiered (INFRA-1380) ==="
echo "Checking: $CI_YML"
echo ""

# ── 1. cargo-test-fast job exists ────────────────────────────────────────────
if grep -q '^  cargo-test-fast:' "$CI_YML"; then
    pass "cargo-test-fast job defined in ci.yml"
else
    fail "cargo-test-fast job NOT found in ci.yml"
fi

# ── 2. cargo-test-slow job exists ────────────────────────────────────────────
if grep -q '^  cargo-test-slow:' "$CI_YML"; then
    pass "cargo-test-slow job defined in ci.yml"
else
    fail "cargo-test-slow job NOT found in ci.yml"
fi

# ── 3. cargo-test-slow depends on cargo-test-fast ────────────────────────────
# Extract the needs block of cargo-test-slow and verify it contains cargo-test-fast.
# We do this by finding the cargo-test-slow: stanza and scanning until the next
# top-level job definition (two-space-indented line that looks like a job key).
SLOW_NEEDS=$(awk '
    /^  cargo-test-slow:/ { in_job=1; next }
    in_job && /^    needs:/ { in_needs=1; next }
    in_job && in_needs && /^      - / { print; next }
    in_job && in_needs && /^    needs: \[/ { print; in_needs=0; next }
    in_job && /^  [a-z]/ { exit }
' "$CI_YML")

if echo "$SLOW_NEEDS" | grep -q "cargo-test-fast"; then
    pass "cargo-test-slow.needs includes cargo-test-fast"
else
    # Also check inline needs: [...] form
    SLOW_NEEDS_INLINE=$(grep -A1 '^  cargo-test-slow:' "$CI_YML" | grep 'needs:' || true)
    if echo "$SLOW_NEEDS_INLINE" | grep -q "cargo-test-fast"; then
        pass "cargo-test-slow.needs includes cargo-test-fast (inline form)"
    else
        fail "cargo-test-slow.needs does NOT include cargo-test-fast (found: '$SLOW_NEEDS')"
    fi
fi

# ── 4. cargo-test-required depends on both tiers ─────────────────────────────
REQ_NEEDS=$(awk '
    /^  cargo-test-required:/ { in_job=1; next }
    in_job && /^    needs:/ { in_needs=1; print; next }
    in_job && in_needs && /^      - / { print; next }
    in_job && in_needs && /^\s*\[/ { print; next }
    in_job && /^    [a-z]/ && !/^    needs/ { in_needs=0 }
    in_job && /^  [a-z]/ { exit }
' "$CI_YML")

if echo "$REQ_NEEDS" | grep -q "cargo-test-fast"; then
    pass "cargo-test-required.needs includes cargo-test-fast"
else
    fail "cargo-test-required.needs does NOT include cargo-test-fast (found: '$REQ_NEEDS')"
fi

if echo "$REQ_NEEDS" | grep -q "cargo-test-slow"; then
    pass "cargo-test-required.needs includes cargo-test-slow"
else
    fail "cargo-test-required.needs does NOT include cargo-test-slow (found: '$REQ_NEEDS')"
fi

# ── 5. cargo-test-fast uses --lib --bins (no --tests) ────────────────────────
FAST_CMD=$(awk '
    /^  cargo-test-fast:/ { in_job=1; next }
    in_job && /cargo test/ { print; next }
    in_job && /^  [a-z]/ { exit }
' "$CI_YML")

if echo "$FAST_CMD" | grep -q "\-\-lib"; then
    pass "cargo-test-fast uses --lib flag"
else
    fail "cargo-test-fast missing --lib flag in cargo test command"
fi

if echo "$FAST_CMD" | grep -q "\-\-bins"; then
    pass "cargo-test-fast uses --bins flag"
else
    fail "cargo-test-fast missing --bins flag in cargo test command"
fi

# Ensure --tests is NOT in the fast job command
if echo "$FAST_CMD" | grep -q "\-\-tests"; then
    fail "cargo-test-fast should NOT use --tests flag (that's for the slow tier)"
else
    pass "cargo-test-fast correctly omits --tests flag"
fi

# ── 6. cargo-test-slow uses --tests ──────────────────────────────────────────
SLOW_CMD=$(awk '
    /^  cargo-test-slow:/ { in_job=1; next }
    in_job && /cargo test/ { print; next }
    in_job && /^  [a-z]/ { exit }
' "$CI_YML")

if echo "$SLOW_CMD" | grep -q "\-\-tests"; then
    pass "cargo-test-slow uses --tests flag"
else
    fail "cargo-test-slow missing --tests flag in cargo test command"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
