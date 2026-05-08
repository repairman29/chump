#!/usr/bin/env bash
# scripts/ci/test-half-impl-detector.sh — INFRA-671
#
# Smoke test for half-impl-detector job in pr-triage-bot.yml
# Validates the workflow has the required job and its detection logic.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WF="$REPO_ROOT/.github/workflows/pr-triage-bot.yml"

echo "=== INFRA-671 half-impl-detector smoke test ==="
echo

# 1. File exists.
if [ -f "$WF" ]; then
    ok "pr-triage-bot.yml exists"
else
    fail "pr-triage-bot.yml missing"
    echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# 2. INFRA-671 marker.
if grep -q 'INFRA-671' "$WF"; then
    ok "INFRA-671 marker present"
else
    fail "INFRA-671 marker missing"
fi

# 3. half-impl-detector job declared.
if grep -q '^  half-impl-detector:' "$WF"; then
    ok "half-impl-detector job declared"
else
    fail "half-impl-detector job missing"
fi

# Helper to extract job section
extract_job() {
    local JOB_NAME="$1"
    sed -n "/^  $JOB_NAME:/,/^[^ ]/p" "$WF"
}

JOB_SECTION=$(extract_job 'half-impl-detector')

# 4. Triggers on check_run events for cargo-test failures.
if echo "$JOB_SECTION" | grep -q 'check_run'; then
    ok "half-impl-detector triggers on check_run"
else
    fail "half-impl-detector doesn't trigger on check_run"
fi

if echo "$JOB_SECTION" | grep -q 'cargo-test'; then
    ok "half-impl-detector filters for cargo-test job"
else
    fail "half-impl-detector doesn't filter for cargo-test"
fi

# 5. Detection pattern includes "no method named" and "cannot find function"
if echo "$JOB_SECTION" | grep -q 'no method named'; then
    ok "pattern includes 'no method named'"
else
    fail "pattern missing 'no method named'"
fi

if echo "$JOB_SECTION" | grep -q 'cannot find function'; then
    ok "pattern includes 'cannot find function'"
else
    fail "pattern missing 'cannot find function'"
fi

# 6. Disables auto-merge on PR.
if echo "$JOB_SECTION" | grep -q 'automerge disable'; then
    ok "disables auto-merge"
else
    fail "doesn't disable auto-merge"
fi

# 7. Files completion gap.
if echo "$JOB_SECTION" | grep -q 'File completion gap'; then
    ok "files completion gap step declared"
else
    fail "doesn't file completion gap"
fi

# 8. Comments on PR.
if echo "$JOB_SECTION" | grep -q 'half-implementation detected'; then
    ok "comments on PR with half-implementation message"
else
    fail "doesn't comment on PR"
fi

# 9. Gap title includes "complete implementation"
if echo "$JOB_SECTION" | grep -q 'complete implementation'; then
    ok "gap title includes 'complete implementation'"
else
    fail "gap title missing 'complete implementation'"
fi

# 10. Bot identity used (check in the entire job section beyond what sed captured).
if grep -A 250 "^  half-impl-detector:" "$WF" | grep -q "chump-pr-triage-bot"; then
    ok "uses bot identity 'chump-pr-triage-bot'"
else
    fail "doesn't use bot identity"
fi

# 11. Detection logic: symbol extraction
# Test the symbol extraction pattern
extract_symbol() {
    local PATTERN='no method named|cannot find function'
    local INPUT="$1"
    local SYMBOL=$(echo "$INPUT" | grep -oE "(?:no method named|cannot find function) \`?[a-z_][a-z0-9_]*" | head -1 | grep -oE "[a-z_][a-z0-9_]*$" || echo "")
    echo "$SYMBOL"
}

SYMBOL=$(extract_symbol "error: no method named render_text found for struct Options")
[[ "$SYMBOL" == "render_text" ]] && ok "extracts symbol from 'no method named' error" || fail "failed to extract symbol from 'no method named'"

SYMBOL=$(extract_symbol "error: cannot find function foo_bar in this scope")
[[ "$SYMBOL" == "foo_bar" ]] && ok "extracts symbol from 'cannot find function' error" || fail "failed to extract symbol from 'cannot find function'"

# 12. Detection logic: callsite vs definition patterns
# Test that callsite pattern matches calls but definition pattern matches definitions
callsite_test() {
    local SYMBOL="$1"
    local TEXT="$2"
    local PATTERN="(\.|->|\s)$SYMBOL\s*\(|$SYMBOL\s*\(|::\s*$SYMBOL\s*\("
    echo "$TEXT" | grep -E "$PATTERN" > /dev/null && echo "true" || echo "false"
}

def_test() {
    local SYMBOL="$1"
    local TEXT="$2"
    local PATTERN="fn\s+$SYMBOL\s*\(|$SYMBOL\s*:\s*fn"
    echo "$TEXT" | grep -E "$PATTERN" > /dev/null && echo "true" || echo "false"
}

# Test: foo() is a callsite
RESULT=$(callsite_test "foo" "let x = foo();")
[[ "$RESULT" == "true" ]] && ok "detects foo() as callsite" || fail "missed foo() callsite"

# Test: fn foo() is a definition
RESULT=$(def_test "foo" "fn foo() { }")
[[ "$RESULT" == "true" ]] && ok "detects 'fn foo()' as definition" || fail "missed 'fn foo()' definition"

# Test: foo() without definition is half-impl
CALLSITE=$(callsite_test "foo" "let x = foo();")
DEF=$(def_test "foo" "let x = foo();")
[[ "$CALLSITE" == "true" ]] && [[ "$DEF" == "false" ]] && ok "detects half-implementation pattern" || fail "missed half-implementation"

# Test: obj.method() is a callsite
RESULT=$(callsite_test "method" "obj.method();")
[[ "$RESULT" == "true" ]] && ok "detects obj.method() as callsite" || fail "missed obj.method() callsite"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -eq 0 ]; then
    exit 0
else
    exit 1
fi
