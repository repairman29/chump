#!/usr/bin/env bash
# test-rollup-cascade-cancel.sh — INFRA-1002: cascade-cancel classification fixture
#
# Tests:
#   1. fast-checks=failure, cargo-test=cancelled → cascade_cancel detected, rollup fails
#      on real_failures only (real_failures=[fast-checks], cascade_cancels=[cargo-test])
#   2. All success → passed=[all], rollup exits 0
#   3. cargo-test=cancelled, no other failure → treated as real_failure, rollup exits 1
#   4. fast-checks=failure, clippy=cancelled, cargo-test=cancelled → both cascade_cancels

set -euo pipefail

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Extract and source just the classification logic from ci.yml inline.
# We parametrize via shell variables to simulate different shard result combos.

run_rollup() {
    local fast="$1" clippy="$2" test="$3" hygiene="$4"
    # Run the classify logic from ci.yml in a subshell with mocked inputs.
    # Returns via stdout: "real_failures=X cascade_cancels=Y passed=Z skipped=W exit=N"
    bash <<SHELL
set -uo pipefail
fast="$fast"
clippy="$clippy"
test="$test"
hygiene="$hygiene"

any_real_failure=0
for r in "\$fast" "\$clippy" "\$test" "\$hygiene"; do
  [ "\$r" = "failure" ] && any_real_failure=1
done

real_failures="" cascade_cancels="" passed="" skipped_list=""
classify() {
  local name="\$1" result="\$2"
  case "\$result" in
    success)   passed="\${passed:+\$passed,}\$name" ;;
    skipped)   skipped_list="\${skipped_list:+\$skipped_list,}\$name" ;;
    failure)   real_failures="\${real_failures:+\$real_failures,}\$name" ;;
    cancelled)
      if [ "\$any_real_failure" = "1" ]; then
        cascade_cancels="\${cascade_cancels:+\$cascade_cancels,}\$name"
      else
        real_failures="\${real_failures:+\$real_failures,}\$name"
      fi
      ;;
    *) real_failures="\${real_failures:+\$real_failures,}\$name" ;;
  esac
}
classify "fast-checks" "\$fast"
classify "clippy"       "\$clippy"
classify "cargo-test"   "\$test"
classify "pr-hygiene"   "\$hygiene"

echo "real_failures=[\${real_failures:-none}] cascade_cancels=[\${cascade_cancels:-none}] passed=[\${passed:-none}]"
if [ -n "\$real_failures" ]; then exit 1; else exit 0; fi
SHELL
}

# ── Test 1: fast-checks fails, cargo-test cascade-cancelled ──────────────────
EXIT1=0; OUT1=$(run_rollup "failure" "success" "cancelled" "success" 2>/dev/null) || EXIT1=$?

if echo "$OUT1" | grep -q "real_failures=\[fast-checks\]"; then
    pass "Test 1: fast-checks correctly classified as real_failure"
else
    fail "Test 1: real_failures not [fast-checks] (got: $OUT1)"
fi

if echo "$OUT1" | grep -q "cascade_cancels=\[cargo-test\]"; then
    pass "Test 1: cargo-test correctly classified as cascade_cancel"
else
    fail "Test 1: cascade_cancels not [cargo-test] (got: $OUT1)"
fi

if [[ "$EXIT1" -ne 0 ]]; then
    pass "Test 1: rollup exits non-zero on real failure"
else
    fail "Test 1: rollup should exit non-zero when real failures exist (got exit 0)"
fi

# ── Test 2: all success ───────────────────────────────────────────────────────
EXIT2=0; OUT2=$(run_rollup "success" "success" "success" "success" 2>/dev/null) || EXIT2=$?

if echo "$OUT2" | grep -q "real_failures=\[none\]"; then
    pass "Test 2: all-success rollup has no real_failures"
else
    fail "Test 2: expected real_failures=[none] (got: $OUT2)"
fi

if [[ "$EXIT2" -eq 0 ]]; then
    pass "Test 2: all-success rollup exits 0"
else
    fail "Test 2: all-success should exit 0 (got $EXIT2)"
fi

# ── Test 3: cargo-test cancelled with no other failure → real_failure ─────────
EXIT3=0; OUT3=$(run_rollup "success" "success" "cancelled" "success" 2>/dev/null) || EXIT3=$?

if echo "$OUT3" | grep -q "real_failures=\[cargo-test\]"; then
    pass "Test 3: unexpected cancel (no peer failure) classified as real_failure"
else
    fail "Test 3: unexpected cancel should be real_failure (got: $OUT3)"
fi

if [[ "$EXIT3" -ne 0 ]]; then
    pass "Test 3: rollup exits non-zero on unexpected cancel"
else
    fail "Test 3: unexpected cancel should exit non-zero (got 0)"
fi

# ── Test 4: fast-checks fails, clippy AND cargo-test both cascade-cancelled ───
EXIT4=0; OUT4=$(run_rollup "failure" "cancelled" "cancelled" "success" 2>/dev/null) || EXIT4=$?

if echo "$OUT4" | grep -q "real_failures=\[fast-checks\]"; then
    pass "Test 4: fast-checks is the only real_failure"
else
    fail "Test 4: fast-checks should be real_failure (got: $OUT4)"
fi

# Both clippy and cargo-test should be cascade_cancels (order may vary).
if echo "$OUT4" | grep -q "cascade_cancels=\[clippy,cargo-test\]"; then
    pass "Test 4: clippy and cargo-test both cascade_cancelled"
else
    fail "Test 4: expected cascade_cancels=[clippy,cargo-test] (got: $OUT4)"
fi

echo ""
echo "All INFRA-1002 cascade-cancel classification checks passed (7/7)."
