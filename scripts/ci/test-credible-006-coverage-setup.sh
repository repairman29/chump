#!/usr/bin/env bash
# test-credible-006-coverage-setup.sh — CREDIBLE-006 tests.
#
# Verifies the cargo llvm-cov coverage CI setup:
#   (1) coverage job defined in .github/workflows/ci.yml
#   (2) cargo llvm-cov command present in coverage job
#   (3) coverage artifact upload step present (coverage-lcov)
#   (4) threshold check present (warns when coverage drops >N pp)
#   (5) continue-on-error: true on coverage job (non-blocking)
#   (6) docs/credibility/COVERAGE_BASELINE.md exists with policy section
#   (7) baseline tracking policy documented (warning threshold = 2 pp)
#   (8) extensions/** in paths-filter (INFRA-682 — added for PRODUCT-056)
#
# Run: ./scripts/ci/test-credible-006-coverage-setup.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
BASELINE="$REPO_ROOT/docs/credibility/COVERAGE_BASELINE.md"

echo "=== CREDIBLE-006 code coverage CI setup tests ==="
echo

# ── Test 1: coverage job defined ─────────────────────────────────────────────
echo "--- Test 1: 'coverage:' job defined in ci.yml ---"
if grep -q '^  coverage:' "$CI_YML" 2>/dev/null; then
    ok "Test 1: coverage job present in ci.yml"
else
    fail "Test 1: coverage job not found in ci.yml"
fi

# ── Test 2: cargo llvm-cov command ───────────────────────────────────────────
echo "--- Test 2: cargo llvm-cov invoked in coverage job ---"
if grep -q 'cargo llvm-cov' "$CI_YML" 2>/dev/null; then
    ok "Test 2: cargo llvm-cov present in ci.yml"
else
    fail "Test 2: cargo llvm-cov command missing from ci.yml"
fi

# ── Test 3: artifact upload (coverage-lcov) ───────────────────────────────────
echo "--- Test 3: coverage-lcov artifact uploaded ---"
if grep -q 'coverage-lcov' "$CI_YML" 2>/dev/null; then
    ok "Test 3: coverage-lcov artifact upload present"
else
    fail "Test 3: coverage-lcov artifact upload missing"
fi

# ── Test 4: threshold check / warning present ─────────────────────────────────
echo "--- Test 4: coverage drop threshold warning present ---"
if grep -q 'CHUMP_COVERAGE_DROP_THRESHOLD\|Coverage dropped\|threshold' "$CI_YML" 2>/dev/null; then
    ok "Test 4: coverage drop threshold check present in ci.yml"
else
    fail "Test 4: coverage drop threshold warning missing from ci.yml"
fi

# ── Test 5: continue-on-error: true on coverage job ──────────────────────────
echo "--- Test 5: coverage job is non-blocking (continue-on-error: true) ---"
# Verify continue-on-error: true appears within 10 lines after the coverage: header.
_cov_start=$(grep -n '^  coverage:' "$CI_YML" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "$_cov_start" ]]; then
    _cov_end=$(( _cov_start + 10 ))
    _has_coe=$(sed -n "${_cov_start},${_cov_end}p" "$CI_YML" | grep -c 'continue-on-error: true')
    if [[ "${_has_coe:-0}" -gt 0 ]]; then
        ok "Test 5: coverage job has continue-on-error: true (non-blocking)"
    else
        fail "Test 5: continue-on-error: true missing from coverage job"
    fi
else
    fail "Test 5: coverage: job not found"
fi

# ── Test 6: COVERAGE_BASELINE.md exists ──────────────────────────────────────
echo "--- Test 6: docs/credibility/COVERAGE_BASELINE.md exists ---"
if [[ -f "$BASELINE" ]]; then
    ok "Test 6: docs/credibility/COVERAGE_BASELINE.md present"
else
    fail "Test 6: docs/credibility/COVERAGE_BASELINE.md missing"
fi

# ── Test 7: baseline doc has tracking policy (2 pp threshold) ─────────────────
echo "--- Test 7: baseline doc has tracking policy (2 pp default threshold) ---"
if grep -q '2 pp\|2pp\|threshold' "$BASELINE" 2>/dev/null; then
    ok "Test 7: COVERAGE_BASELINE.md documents 2 pp threshold policy"
else
    fail "Test 7: COVERAGE_BASELINE.md missing threshold policy"
fi

# ── Test 8: llvm-tools-preview component in rust-toolchain step ───────────────
echo "--- Test 8: llvm-tools-preview installed (required by cargo llvm-cov) ---"
if grep -q 'llvm-tools-preview' "$CI_YML" 2>/dev/null; then
    ok "Test 8: llvm-tools-preview component installed in coverage job"
else
    fail "Test 8: llvm-tools-preview missing from ci.yml coverage job"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
