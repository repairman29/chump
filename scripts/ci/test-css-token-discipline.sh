#!/usr/bin/env bash
# test-css-token-discipline.sh — INFRA-1590
#
# Smoke-tests scripts/lint/css-token-discipline.sh against:
#   tests/fixtures/css-token-violation.html  → linter must exit non-zero
#   tests/fixtures/css-token-clean.html      → linter must exit 0
#
# Also asserts the supporting artifacts exist:
#   .css-discipline-baseline.txt
#   docs/process/CSS_TOKEN_DISCIPLINE.md
#   CLAUDE.md references the docs page

set -uo pipefail

PASS=0
FAIL=0

ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/../.." && pwd)"
LINTER="${REPO_ROOT}/scripts/lint/css-token-discipline.sh"
VIOLATION_FIXTURE="${REPO_ROOT}/tests/fixtures/css-token-violation.html"
CLEAN_FIXTURE="${REPO_ROOT}/tests/fixtures/css-token-clean.html"

printf '=== INFRA-1590 css-token-discipline test ===\n\n'

# 1. Linter exists and is executable
if [[ -x "$LINTER" ]]; then
    ok "linter exists and is executable"
else
    fail "linter missing or not executable: $LINTER"
fi

# 2. Test fixtures exist
if [[ -f "$VIOLATION_FIXTURE" ]]; then
    ok "violation fixture exists"
else
    fail "violation fixture missing: $VIOLATION_FIXTURE"
fi

if [[ -f "$CLEAN_FIXTURE" ]]; then
    ok "clean fixture exists"
else
    fail "clean fixture missing: $CLEAN_FIXTURE"
fi

# 3. Linter exits non-zero on violation fixture (Rule 1: raw hex outside :root)
if [[ -x "$LINTER" && -f "$VIOLATION_FIXTURE" ]]; then
    if CHUMP_TOKEN_DISCIPLINE_FILES="$VIOLATION_FIXTURE" \
       CHUMP_TOKEN_DISCIPLINE_CHECK=1 \
       bash "$LINTER" 2>/dev/null; then
        fail "linter should reject violation fixture (exit non-zero) but exited 0"
    else
        ok "linter exits non-zero on violation fixture"
    fi
fi

# 4. Linter exits 0 on clean fixture
if [[ -x "$LINTER" && -f "$CLEAN_FIXTURE" ]]; then
    if CHUMP_TOKEN_DISCIPLINE_FILES="$CLEAN_FIXTURE" \
       CHUMP_TOKEN_DISCIPLINE_CHECK=1 \
       bash "$LINTER" 2>/dev/null; then
        ok "linter exits 0 on clean fixture"
    else
        fail "linter should accept clean fixture (exit 0) but exited non-zero"
    fi
fi

# 5. Baseline file exists
if [[ -f "${REPO_ROOT}/.css-discipline-baseline.txt" ]]; then
    ok ".css-discipline-baseline.txt exists"
else
    fail ".css-discipline-baseline.txt missing"
fi

# 6. Docs page exists
if [[ -f "${REPO_ROOT}/docs/process/CSS_TOKEN_DISCIPLINE.md" ]]; then
    ok "docs/process/CSS_TOKEN_DISCIPLINE.md exists"
else
    fail "docs/process/CSS_TOKEN_DISCIPLINE.md missing"
fi

# 7. CLAUDE.md Hard rules section links to the doc
if grep -q 'CSS_TOKEN_DISCIPLINE' "${REPO_ROOT}/CLAUDE.md" 2>/dev/null; then
    ok "CLAUDE.md references CSS_TOKEN_DISCIPLINE.md"
else
    fail "CLAUDE.md missing reference to CSS_TOKEN_DISCIPLINE.md"
fi

# 8. Bypass trailer suppresses gate (no commit message file → no bypass, but
#    we test the env-var disable path as a proxy for the bypass logic)
if [[ -x "$LINTER" && -f "$VIOLATION_FIXTURE" ]]; then
    if CHUMP_TOKEN_DISCIPLINE_CHECK=0 \
       CHUMP_TOKEN_DISCIPLINE_FILES="$VIOLATION_FIXTURE" \
       bash "$LINTER" 2>/dev/null; then
        ok "CHUMP_TOKEN_DISCIPLINE_CHECK=0 disables gate"
    else
        fail "CHUMP_TOKEN_DISCIPLINE_CHECK=0 should disable gate but still blocked"
    fi
fi

# 9. Event kind registered in EVENT_REGISTRY.yaml
if grep -q 'token_discipline_bypass' "${REPO_ROOT}/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
    ok "token_discipline_bypass registered in EVENT_REGISTRY.yaml"
else
    fail "token_discipline_bypass missing from EVENT_REGISTRY.yaml"
fi

# 10. Pre-commit hook wired (hook mentions css-token-discipline)
if grep -q 'css-token-discipline' "${REPO_ROOT}/scripts/git-hooks/pre-commit" 2>/dev/null; then
    ok "pre-commit hook wired to css-token-discipline"
else
    fail "pre-commit hook not wired to css-token-discipline"
fi

printf '\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
