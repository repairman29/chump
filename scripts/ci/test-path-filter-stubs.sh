#!/usr/bin/env bash
# scripts/ci/test-path-filter-stubs.sh — INFRA-1143 (2026-05-14)
#
# Validates that the synthetic-green stub pattern is correctly wired in
# .github/workflows/ci.yml for all required CI checks.
#
# Tests:
#   1. clippy-stub job exists with correct condition (code != true && PR only)
#   2. clippy-required job exists with always() and needs both
#   3. cargo-test-stub job exists with correct condition
#   4. cargo-test-required job exists with always() and needs both
#   5. fast-checks-stub job exists with correct condition
#   6. fast-checks-required job exists with always() and needs both
#   7. audit-stub job exists with correct condition
#   8. audit-required job exists with always() and needs both
#   9. Each -required rollup uses exit 1 on failure (not just echo)
#  10. INFRA-1143 marker present in ci.yml
#  11. Migration path documented in scripts/coord/README.md

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
README="$REPO_ROOT/scripts/coord/README.md"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1143 synthetic-green stub pattern test ==="
echo

# ── YAML validity ──────────────────────────────────────────────────────────────
if python3 -c "import yaml, sys; yaml.safe_load(open('$CI_YML'))" 2>/dev/null; then
    ok "ci.yml is valid YAML"
else
    fail "ci.yml YAML parse error"
fi

# ── Helper: check stub job exists with proper condition ───────────────────────
check_stub() {
    local stub_job="$1"
    local real_job="$2"
    # Stub must exist
    if grep -q "^  ${stub_job}:" "$CI_YML"; then
        ok "${stub_job}: job defined"
    else
        fail "${stub_job}: job missing"
        return
    fi
    # Stub condition must include code != true
    if grep -A5 "^  ${stub_job}:" "$CI_YML" | grep -q "code.*!=.*true\|!= 'true'"; then
        ok "${stub_job}: condition excludes code-change paths"
    else
        fail "${stub_job}: missing 'code != true' condition"
    fi
    # Corresponding -required job must exist
    local req_job="${real_job}-required"
    if grep -q "^  ${req_job}:" "$CI_YML"; then
        ok "${req_job}: rollup job defined"
    else
        fail "${req_job}: rollup job missing"
        return
    fi
    # Rollup must have always()
    if grep -A3 "^  ${req_job}:" "$CI_YML" | grep -q "always()"; then
        ok "${req_job}: uses if: always()"
    else
        fail "${req_job}: missing if: always()"
    fi
    # Rollup must need both real and stub
    if grep -A5 "^  ${req_job}:" "$CI_YML" | grep -q "${real_job}" && \
       grep -A5 "^  ${req_job}:" "$CI_YML" | grep -q "${stub_job}"; then
        ok "${req_job}: needs both ${real_job} and ${stub_job}"
    else
        fail "${req_job}: missing needs on ${real_job} or ${stub_job}"
    fi
}

check_stub "clippy-stub"      "clippy"
check_stub "cargo-test-stub"  "cargo-test"
check_stub "fast-checks-stub" "fast-checks"
check_stub "audit-stub"       "audit"

# ── Test 9: -required rollups use exit 1 on failure ───────────────────────────
ROLLUP_FAIL_COUNT=$(grep -c "exit 1" "$CI_YML" || echo 0)
if [[ "$ROLLUP_FAIL_COUNT" -ge 4 ]]; then
    ok "at least 4 'exit 1' entries in rollup jobs (one per required check)"
else
    fail "expected ≥4 'exit 1' in rollup jobs, got $ROLLUP_FAIL_COUNT"
fi

# ── Test 10: INFRA-1143 marker in ci.yml ─────────────────────────────────────
if grep -q "INFRA-1143" "$CI_YML"; then
    ok "INFRA-1143 marker present in ci.yml"
else
    fail "INFRA-1143 marker missing from ci.yml"
fi

# ── Test 11: Migration path documented in README ──────────────────────────────
if [[ -r "$README" ]] && grep -q "INFRA-1143\|Required-check stub\|-required" "$README"; then
    ok "scripts/coord/README.md documents the synthetic-green stub migration path"
else
    fail "scripts/coord/README.md missing INFRA-1143 / Required-check stub documentation"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
