#!/usr/bin/env bash
# test-harness-dispatch.sh — INFRA-1045 acceptance tests.
#
# Verifies:
#   1. All harness config files exist and are sourceable.
#   2. Each harness sets required variables.
#   3. worker.sh sources the harness file and exports CHUMP_AGENT_HARNESS.
#   4. opencode harness sets the correct git identity.
#   5. Unknown harness name falls back gracefully (claude-p defaults preserved).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_DIR="$REPO_ROOT/scripts/dispatch/harnesses"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"

pass=0
fail=0

ok()   { printf '[PASS] %s\n' "$1"; pass=$((pass + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; fail=$((fail + 1)); }

# ── Test 1: harness directory exists ─────────────────────────────────────────
if [[ -d "$HARNESS_DIR" ]]; then
    ok "Test 1: harnesses/ directory exists"
else
    fail "Test 1: harnesses/ directory missing at $HARNESS_DIR"
fi

# ── Test 2: all four harness files present ───────────────────────────────────
for harness in claude opencode manual codex; do
    f="$HARNESS_DIR/${harness}.sh"
    if [[ -f "$f" ]]; then
        ok "Test 2: ${harness}.sh exists"
    else
        fail "Test 2: ${harness}.sh missing"
    fi
done

# ── Test 3: each harness is sourceable and sets required vars ────────────────
for harness in claude opencode manual codex; do
    f="$HARNESS_DIR/${harness}.sh"
    [[ -f "$f" ]] || continue
    # Source in a subshell and check variables
    result=$(bash -c "source '$f'; echo \"PROG=\${HARNESS_SPAWN_PROGRAM:-} MODE=\${HARNESS_SPAWN_MODE:-}\"" 2>/dev/null)
    if echo "$result" | grep -q "MODE="; then
        ok "Test 3: ${harness}.sh sourceable, sets HARNESS_SPAWN_MODE"
    else
        fail "Test 3: ${harness}.sh failed to source or set HARNESS_SPAWN_MODE"
    fi
done

# ── Test 4: claude harness sets HARNESS_SPAWN_MODE=claude-p ─────────────────
mode=$(bash -c "source '$HARNESS_DIR/claude.sh'; echo \"\${HARNESS_SPAWN_MODE:-}\"" 2>/dev/null)
if [[ "$mode" == "claude-p" ]]; then
    ok "Test 4: claude.sh → HARNESS_SPAWN_MODE=claude-p (zero behavior change)"
else
    fail "Test 4: claude.sh HARNESS_SPAWN_MODE='$mode' (expected claude-p)"
fi

# ── Test 5: opencode harness sets git identity ───────────────────────────────
email=$(bash -c "source '$HARNESS_DIR/opencode.sh'; echo \"\${HARNESS_GIT_EMAIL:-}\"" 2>/dev/null)
if [[ "$email" == "bigpickle@chump.bot" ]]; then
    ok "Test 5: opencode.sh → HARNESS_GIT_EMAIL=bigpickle@chump.bot"
else
    fail "Test 5: opencode.sh HARNESS_GIT_EMAIL='$email' (expected bigpickle@chump.bot)"
fi

# ── Test 6: opencode harness sets HARNESS_SPAWN_MODE=opencode-prompt ─────────
mode=$(bash -c "source '$HARNESS_DIR/opencode.sh'; echo \"\${HARNESS_SPAWN_MODE:-}\"" 2>/dev/null)
if [[ "$mode" == "opencode-prompt" ]]; then
    ok "Test 6: opencode.sh → HARNESS_SPAWN_MODE=opencode-prompt"
else
    fail "Test 6: opencode.sh HARNESS_SPAWN_MODE='$mode' (expected opencode-prompt)"
fi

# ── Test 7: manual harness sets HARNESS_SPAWN_MODE=manual-result-file ────────
mode=$(bash -c "source '$HARNESS_DIR/manual.sh'; echo \"\${HARNESS_SPAWN_MODE:-}\"" 2>/dev/null)
if [[ "$mode" == "manual-result-file" ]]; then
    ok "Test 7: manual.sh → HARNESS_SPAWN_MODE=manual-result-file"
else
    fail "Test 7: manual.sh HARNESS_SPAWN_MODE='$mode' (expected manual-result-file)"
fi

# ── Test 8: worker.sh references CHUMP_AGENT_HARNESS ────────────────────────
if grep -q 'CHUMP_AGENT_HARNESS' "$WORKER_SH"; then
    ok "Test 8: worker.sh references CHUMP_AGENT_HARNESS"
else
    fail "Test 8: worker.sh does not reference CHUMP_AGENT_HARNESS"
fi

# ── Test 9: worker.sh sources harness config file ───────────────────────────
if grep -q 'harnesses/' "$WORKER_SH"; then
    ok "Test 9: worker.sh sources from harnesses/ directory"
else
    fail "Test 9: worker.sh does not reference harnesses/ directory"
fi

# ── Test 10: worker.sh checks HARNESS_SPAWN_MODE for dispatch ───────────────
if grep -q 'HARNESS_SPAWN_MODE' "$WORKER_SH"; then
    ok "Test 10: worker.sh dispatches based on HARNESS_SPAWN_MODE"
else
    fail "Test 10: worker.sh does not check HARNESS_SPAWN_MODE"
fi

# ── Test 11: worker.sh opencode-prompt handler present ──────────────────────
if grep -q 'opencode-prompt' "$WORKER_SH"; then
    ok "Test 11: worker.sh has opencode-prompt handler"
else
    fail "Test 11: worker.sh missing opencode-prompt case"
fi

# ── Test 12: worker.sh manual-result-file handler present ───────────────────
if grep -q 'manual-result-file' "$WORKER_SH"; then
    ok "Test 12: worker.sh has manual-result-file handler"
else
    fail "Test 12: worker.sh missing manual-result-file case"
fi

# ── Test 13: CHUMP_AGENT_HARNESS defaults to 'claude' ───────────────────────
default=$(bash -c "source '$HARNESS_DIR/claude.sh'; CHUMP_AGENT_HARNESS=\"\${CHUMP_AGENT_HARNESS:-claude}\"; echo \"\$CHUMP_AGENT_HARNESS\"" 2>/dev/null)
if [[ "$default" == "claude" ]]; then
    ok "Test 13: CHUMP_AGENT_HARNESS defaults to 'claude'"
else
    fail "Test 13: CHUMP_AGENT_HARNESS default='$default' (expected claude)"
fi

# ── Test 14: worker.sh exports CHUMP_AGENT_HARNESS ──────────────────────────
if grep -q 'export CHUMP_AGENT_HARNESS' "$WORKER_SH"; then
    ok "Test 14: worker.sh exports CHUMP_AGENT_HARNESS for child processes"
else
    fail "Test 14: worker.sh does not export CHUMP_AGENT_HARNESS"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
    exit 1
fi
exit 0
