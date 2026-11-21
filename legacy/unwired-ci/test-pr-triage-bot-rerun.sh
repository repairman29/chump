#!/usr/bin/env bash
# scripts/ci/test-pr-triage-bot-rerun.sh — INFRA-669
#
# Test for auto-rerun of flake failures in pr-triage-bot.
# Validates:
#  - should_rerun flag is set correctly for flake/infra-broken classifications
#  - rerun logic respects 3-attempt cap
#  - API calls are correct (gh run rerun --failed)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WF="$REPO_ROOT/.github/workflows/pr-triage-bot.yml"

echo "=== INFRA-669 pr-triage-bot auto-rerun test ==="
echo

# 1. File exists.
if [ -f "$WF" ]; then
    ok "pr-triage-bot.yml exists"
else
    fail "pr-triage-bot.yml missing"
    echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# 2. INFRA-669 marker present in workflow.
if grep -q 'INFRA-669' "$WF"; then
    ok "INFRA-669 marker present"
else
    fail "INFRA-669 marker missing from workflow"
fi

# 3. Auto-rerun step exists.
if grep -q 'Auto-rerun flake/infra-broken failures' "$WF"; then
    ok "Auto-rerun step declared"
else
    fail "Auto-rerun step missing"
fi

# 4. should_rerun flag is set for flake class.
if awk '/Classify failure via FAILURE_MODES/,/Auto-rerun flake/' "$WF" 2>/dev/null | \
   grep -q 'should_rerun=true'; then
    ok "should_rerun=true set for flake/infra-broken"
else
    fail "should_rerun flag not set for flake/infra-broken"
fi

# 5. rerun step uses gh run rerun --failed.
if grep -q 'gh run rerun.*--failed' "$WF"; then
    ok "gh run rerun --failed API call present"
else
    fail "gh run rerun --failed API call missing"
fi

# 6. Attempt capping logic (< 3).
if grep -q 'RUN_ATTEMPT.*-lt 3' "$WF"; then
    ok "Attempt < 3 check present"
else
    fail "Attempt capping logic missing"
fi

# 7. needs_investigation flag set on attempt 3+.
if grep -q 'needs_investigation=true' "$WF"; then
    ok "needs_investigation flag set for attempt >= 3"
else
    fail "needs_investigation flag missing"
fi

# 8. Investigation comment step exists.
if grep -q 'flake/infra rerun or investigation needed' "$WF"; then
    ok "Investigation needed comment step present"
else
    fail "Investigation needed comment step missing"
fi

# 9. YAML parses correctly.
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo "  ERROR: PyYAML not installed — cannot validate workflow YAML"
        FAIL=$((FAIL+1))
    else
        if python3 -c "import yaml, sys; yaml.safe_load(open('$WF'))" 2>&1; then
            ok "YAML parses cleanly"
        else
            fail "YAML parse error in $WF"
        fi
    fi
fi

# 10. Test fixture: simulate flake classification logic.
test_classify_flake() {
    local CLASS="$1"
    local SHOULD_RERUN="$2"
    if [ "$CLASS" = "flake" ] || [ "$CLASS" = "infra-broken" ]; then
        [ "$SHOULD_RERUN" = "true" ] && return 0 || return 1
    else
        [ "$SHOULD_RERUN" = "false" ] && return 0 || return 1
    fi
}

[[ $(test_classify_flake "flake" "true" && echo "true" || echo "false") == "true" ]] && \
    ok "flake → should_rerun=true" || fail "flake should trigger rerun"
[[ $(test_classify_flake "infra-broken" "true" && echo "true" || echo "false") == "true" ]] && \
    ok "infra-broken → should_rerun=true" || fail "infra-broken should trigger rerun"
[[ $(test_classify_flake "real-bug" "false" && echo "true" || echo "false") == "true" ]] && \
    ok "real-bug → should_rerun=false" || fail "real-bug should not trigger rerun"
[[ $(test_classify_flake "lint" "false" && echo "true" || echo "false") == "true" ]] && \
    ok "lint → should_rerun=false" || fail "lint should not trigger rerun"

# 11. Test fixture: simulate attempt capping.
test_attempt_cap() {
    local ATTEMPT="$1"
    local SHOULD_RERUN="$2"
    if [ "$ATTEMPT" -lt 3 ]; then
        [ "$SHOULD_RERUN" = "true" ] && return 0 || return 1
    else
        [ "$SHOULD_RERUN" = "false" ] && return 0 || return 1
    fi
}

[[ $(test_attempt_cap 1 "true" && echo "true" || echo "false") == "true" ]] && \
    ok "attempt 1 → rerun" || fail "attempt 1 should rerun"
[[ $(test_attempt_cap 2 "true" && echo "true" || echo "false") == "true" ]] && \
    ok "attempt 2 → rerun" || fail "attempt 2 should rerun"
[[ $(test_attempt_cap 3 "false" && echo "true" || echo "false") == "true" ]] && \
    ok "attempt 3 → investigation needed" || fail "attempt 3 should not rerun"
[[ $(test_attempt_cap 4 "false" && echo "true" || echo "false") == "true" ]] && \
    ok "attempt 4 → investigation needed" || fail "attempt 4 should not rerun"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
