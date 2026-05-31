#!/usr/bin/env bash
# scripts/ci/test-path-filter-stubs.sh — META-261 (2026-05-31, was INFRA-1143 2026-05-14)
#
# META-261: the stub/required pair pattern (INFRA-1143) was collapsed. The 4
# synthetic-green stub jobs (clippy-stub, cargo-test-stub, fast-checks-stub,
# audit-stub) are deleted. Each *-required aggregator now maps the real job's
# SKIPPED result directly to exit 0 via needs.result check. This file guards
# the collapsed pattern — asserting stubs are ABSENT and aggregators use the
# new native SKIPPED-as-pass logic.
#
# Tests:
#   1. Stub jobs are absent from ci.yml (no clippy-stub, cargo-test-stub, etc.)
#   2. Each *-required job exists with if: always()
#   3. Each *-required job needs only the real job (not a stub)
#   4. Each *-required job maps skipped → exit 0 (SKIPPED-as-pass)
#   5. Each *-required job uses exit 1 on genuine failure
#   6. META-261 marker present in ci.yml
#   7. Migration path documented in scripts/coord/README.md

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
README="$REPO_ROOT/scripts/coord/README.md"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== META-261 collapsed stub/required pattern test ==="
echo

# ── YAML validity ──────────────────────────────────────────────────────────────
if python3 -c "import yaml, sys; yaml.safe_load(open('$CI_YML'))" 2>/dev/null; then
    ok "ci.yml is valid YAML"
else
    fail "ci.yml YAML parse error"
fi

# ── Test 1: Stub jobs must be absent ──────────────────────────────────────────
for stub_job in clippy-stub cargo-test-stub fast-checks-stub audit-stub; do
    if grep -q "^  ${stub_job}:" "$CI_YML"; then
        fail "${stub_job}: still present — META-261 requires this stub to be deleted"
    else
        ok "${stub_job}: absent (correctly deleted)"
    fi
done

# ── Helper: check *-required aggregator uses new native SKIPPED-as-pass ───────
check_required() {
    local real_job="$1"
    local req_job="${real_job}-required"

    # Must exist
    if ! grep -q "^  ${req_job}:" "$CI_YML"; then
        fail "${req_job}: job missing"
        return
    fi
    ok "${req_job}: job defined"

    # Must have always()
    if grep -A3 "^  ${req_job}:" "$CI_YML" | grep -q "always()"; then
        ok "${req_job}: uses if: always()"
    else
        fail "${req_job}: missing if: always()"
    fi

    # Must need only the real job (no stub in needs)
    local needs_line
    needs_line="$(grep -A5 "^  ${req_job}:" "$CI_YML" | grep "needs:")"
    if echo "$needs_line" | grep -q "${real_job}" && \
       ! echo "$needs_line" | grep -q "${real_job}-stub"; then
        ok "${req_job}: needs only ${real_job} (no stub dependency)"
    else
        fail "${req_job}: needs line wrong — expected '${real_job}' only, got: $needs_line"
    fi

    # Must map skipped → success (SKIPPED-as-pass via exit 0)
    if grep -A20 "^  ${req_job}:" "$CI_YML" | grep -q "skipped"; then
        ok "${req_job}: skipped result maps to PASS"
    else
        fail "${req_job}: missing skipped → PASS mapping"
    fi

    # Must use exit 1 on failure
    if grep -A20 "^  ${req_job}:" "$CI_YML" | grep -q "exit 1"; then
        ok "${req_job}: uses exit 1 on failure"
    else
        fail "${req_job}: missing exit 1 on failure"
    fi
}

check_required "clippy"
check_required "cargo-test"
check_required "fast-checks"
check_required "audit"

# ── Test 6: META-261 marker in ci.yml ─────────────────────────────────────────
if grep -q "META-261" "$CI_YML"; then
    ok "META-261 marker present in ci.yml"
else
    fail "META-261 marker missing from ci.yml"
fi

# ── Test 7: Migration path documented in README ───────────────────────────────
if [[ -r "$README" ]] && grep -q "INFRA-1143\|Required-check stub\|-required" "$README"; then
    ok "scripts/coord/README.md documents the required-check aggregator pattern"
else
    fail "scripts/coord/README.md missing INFRA-1143 / required-check documentation"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
