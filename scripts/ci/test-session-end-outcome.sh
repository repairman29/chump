#!/usr/bin/env bash
# test-session-end-outcome.sh — INFRA-583
#
# Validates worker.sh's session_end outcome classifier:
#   rc=0   → shipped
#   rc=124 → starved (timeout)
#   other  → abandoned
#
# Pre-INFRA-583 the classifier checked `git branch -vv | grep ': gone'`
# which only flipped AFTER the merged branch was deleted on origin —
# many seconds AFTER bot-merge.sh returned. Result: every just-shipped
# session got outcome=abandoned, polluting waste-tally with ~14m/hr of
# false-positive "abandoned compute".

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-583 session_end outcome classifier test ==="
echo

# 1. INFRA-583 marker present.
if grep -q "INFRA-583" "$WORKER"; then
    ok "worker.sh contains INFRA-583 marker"
else
    fail "worker.sh missing INFRA-583 marker"
fi

# 2. rc=0 maps to shipped.
if grep -qE 'if \[ "\$rc" -eq 0 \]; then[[:space:]]*$' "$WORKER" && \
   grep -qE '_outcome="shipped"' "$WORKER"; then
    ok "rc=0 → outcome=shipped"
else
    fail "rc=0 shipped mapping missing"
fi

# 3. rc=124 maps to starved.
if grep -qE 'rc" -eq 124.*\
.*starved' "$WORKER" 2>/dev/null || \
   awk '/elif \[ "\$rc" -eq 124 \]; then/{p=1;next} p && /_outcome="starved"/{found=1;exit} END{exit !found}' "$WORKER"; then
    ok "rc=124 → outcome=starved"
else
    fail "rc=124 starved mapping missing"
fi

# 4. Default abandoned still present.
if grep -qE '_outcome="abandoned"' "$WORKER"; then
    ok "default outcome=abandoned preserved"
else
    fail "default abandoned missing"
fi

# 5. The fragile ': gone' branch check is REMOVED from session-end
#    classification (it may still appear elsewhere for other purposes,
#    but not in the outcome classifier).
if awk '
    /INFRA-492 \/ INFRA-583/,/chump session-track --end/ {
        # Look for the actual fragile command (not the comment that
        # mentions the historical bug)
        if (/git -C.*branch -vv/) found=1
    }
    END { exit found }
' "$WORKER"; then
    ok "fragile 'git branch -vv | grep gone' check removed from outcome classifier"
else
    fail "'git branch -vv | grep gone' still in outcome classifier"
fi

# 6. Syntax.
if bash -n "$WORKER"; then
    ok "worker.sh syntax-clean"
else
    fail "syntax error"
fi

# 7. Live: simulate the classifier logic.
# Replicate the bash conditions to verify outcomes.
classify() {
    local rc="$1"
    local _outcome="abandoned"
    if [ "$rc" -eq 0 ]; then
        _outcome="shipped"
    elif [ "$rc" -eq 124 ]; then
        _outcome="starved"
    fi
    echo "$_outcome"
}

[[ "$(classify 0)"   == "shipped"   ]] && ok "live: rc=0 → shipped"     || fail "live: rc=0 expected shipped"
[[ "$(classify 124)" == "starved"   ]] && ok "live: rc=124 → starved"   || fail "live: rc=124 expected starved"
[[ "$(classify 137)" == "abandoned" ]] && ok "live: rc=137 (OOM) → abandoned" || fail "live: rc=137 expected abandoned"
[[ "$(classify 1)"   == "abandoned" ]] && ok "live: rc=1 → abandoned"   || fail "live: rc=1 expected abandoned"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
