#!/usr/bin/env bash
# scripts/ci/test-auto-flip-on-merge.sh — INFRA-2121 smoke test.
#
# Asserts the regex contract that .github/workflows/auto-flip-on-merge.yml
# and scripts/ops/backfill-shipped-gaps.sh both rely on.
#
# We cannot exercise the actual GH Action from here (no merge event), but
# we CAN:
#   1. Validate the YAML parses (catches column-1-in-pipe-scalar mistakes).
#   2. Exercise the regex against known PR titles (positive + negative cases).
#   3. Smoke-run the backfill in --dry-run mode and assert it exits 0.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# ── Test 1: workflow YAML parses ────────────────────────────────────────────
echo ""
echo "Test 1: .github/workflows/auto-flip-on-merge.yml parses as YAML"
if python3 -c "import yaml; yaml.safe_load(open('.github/workflows/auto-flip-on-merge.yml'))" 2>/dev/null; then
    pass "yaml parses"
else
    fail "yaml parse failed"
fi

# ── Test 2: regex matches the documented positive cases ─────────────────────
echo ""
echo "Test 2: regex matches positive cases"
regex='^([a-z]+\()?(INFRA|EFFECTIVE|RESILIENT|DOC|META|MISSION|CREDIBLE)-([0-9]+)'
expect_match() {
    local title="$1" want_id="$2"
    if [[ "$title" =~ $regex ]]; then
        local got="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        if [[ "$got" == "$want_id" ]]; then
            pass "title '$title' → $got"
        else
            fail "title '$title' → got $got, want $want_id"
        fi
    else
        fail "title '$title' did not match (want $want_id)"
    fi
}
expect_match "INFRA-2121: auto-flip-on-merge" "INFRA-2121"
expect_match "fix(INFRA-2080): sandbox isolation" "INFRA-2080"
expect_match "feat(META-118): wedge auto-dispatch decompose" "META-118"
expect_match "docs(DOC-061): cross-link FRESHNESS_DISCIPLINE" "DOC-061"
expect_match "feat(EFFECTIVE-025): chump fleet autopilot CLI" "EFFECTIVE-025"
expect_match "feat(RESILIENT-031): admin-merge noise-class gate" "RESILIENT-031"

# ── Test 3: regex does NOT match negative cases ─────────────────────────────
echo ""
echo "Test 3: regex skips non-gap PRs"
expect_no_match() {
    local title="$1"
    if [[ "$title" =~ $regex ]]; then
        fail "title '$title' unexpectedly matched"
    else
        pass "title '$title' correctly skipped"
    fi
}
expect_no_match "chore(deps): bump cargo-major group"
expect_no_match "Update README"
expect_no_match "Merge pull request #1234"
# Lowercase gap-domain should NOT match — keeps the contract tight.
expect_no_match "fix(infra-2080): lowercase domain"
# Numbers-only should NOT match — the prefix is required.
expect_no_match "2080: bare number"

# ── Test 4: backfill --dry-run exits 0 ──────────────────────────────────────
# Only runs if chump + gh are on PATH (CI runners have both).
echo ""
echo "Test 4: backfill --dry-run runs without crashing"
if command -v chump >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    # 7-day window keeps the test fast (typical: <100 PRs in 7d).
    if bash scripts/ops/backfill-shipped-gaps.sh --days 7 --dry-run >/dev/null 2>&1; then
        pass "backfill --dry-run exits 0"
    else
        fail "backfill --dry-run exited non-zero"
    fi
else
    echo "[SKIP] chump or gh not in PATH"
fi

# ── Test 5: backfill rejects unknown flag ───────────────────────────────────
echo ""
echo "Test 5: backfill rejects unknown flag with exit 1"
if bash scripts/ops/backfill-shipped-gaps.sh --bogus-flag 2>/dev/null; then
    fail "backfill accepted --bogus-flag (should reject)"
else
    pass "backfill rejected --bogus-flag"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
