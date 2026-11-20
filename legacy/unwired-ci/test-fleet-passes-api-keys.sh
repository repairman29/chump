#!/usr/bin/env bash
# INFRA-417 — verify run-fleet.sh propagates API keys to worker panes.
#
# Pre-fix, INFRA-351 sourced .env into the launcher process but `tmux
# split-window` runs the new pane under the long-lived tmux server, which
# does NOT inherit the launcher's exported env. Result: claude -p in
# workers fell back to the user's claude.ai $20/mo subscription cap
# instead of consuming workspace API credit (the exact failure INFRA-351
# was supposed to fix).
#
# Static check on the worker_env array. Behavioral check via
# FLEET_DRY_RUN=1.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$REPO_ROOT/scripts/dispatch/run-fleet.sh"

[[ -f "$S" ]] || { fail "run-fleet.sh missing"; exit 1; }
pass "run-fleet.sh present"

# 1. ANTHROPIC_API_KEY explicitly listed in worker_env block.
if awk '/worker_env=\(/,/^\)/' "$S" | grep -q 'ANTHROPIC_API_KEY'; then
    pass "ANTHROPIC_API_KEY listed in worker_env"
else
    fail "ANTHROPIC_API_KEY missing from worker_env"
fi

# 2. Other common keys present (OPENAI / TOGETHER / GROQ).
for k in OPENAI_API_KEY TOGETHER_API_KEY GROQ_API_KEY; do
    if awk '/worker_env=\(/,/^\)/' "$S" | grep -q "$k"; then
        pass "$k listed in worker_env"
    else
        fail "$k missing from worker_env"
    fi
done

# 3. Conditional inclusion (avoid pushing empty values that would mask
#    a legitimately-set system-level key). The ${VAR:+...} pattern.
if awk '/worker_env=\(/,/^\)/' "$S" | grep -q '\${ANTHROPIC_API_KEY:+'; then
    pass "ANTHROPIC_API_KEY uses :+ conditional (omits when empty)"
else
    fail "ANTHROPIC_API_KEY should use \${VAR:+...} conditional pattern"
fi

# 4. Behavioral: bash -n syntax check.
if bash -n "$S"; then
    pass "run-fleet.sh syntax clean"
else
    fail "run-fleet.sh syntax error"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
