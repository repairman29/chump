#!/usr/bin/env bash
# test-session-start-emit.sh — INFRA-102 regression test
#
# CLAUDE.md advertises session_start as one of the ambient.jsonl event kinds
# an agent should pick up via peripheral vision. The 2026-04-26 audit found
# a 50-row tail with zero session_start events: FLEET-019/022 wired
# session_end on the Stop hook but never wired the symmetric session_start
# emit on the SessionStart hook.
#
# This test guards both restored emit paths so the regression cannot recur:
#   (1) ambient-context-inject.sh emits session_start when invoked as the
#       SessionStart Claude Code hook
#   (2) gap-claim.sh emits session_start as a fallback for non-Claude-Code
#       dispatch paths (chump-local, Cursor, manual)
#   (3) the bypass env CHUMP_AMBIENT_SESSION_START_EMIT=0 disables both
#
# Run from repo root: bash scripts/ci/test-session-start-emit.sh

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INJECT="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"
EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
[[ -x "$INJECT" ]] || { echo "FATAL: $INJECT not executable"; exit 2; }
[[ -x "$EMIT" ]]   || { echo "FATAL: $EMIT not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== session_start emit tests (INFRA-102) ==="

# ── 1. ambient-context-inject.sh emits session_start on SessionStart hook ────
echo "Test 1: SessionStart hook emit"
TEST_LOG_1="$TMP/ambient-1.jsonl"
CHUMP_SESSION_ID="test-infra-102-hook" \
CHUMP_AMBIENT_LOG="$TEST_LOG_1" \
CHUMP_AMBIENT_INJECT=0 \
    "$INJECT" SessionStart >/dev/null 2>&1 || true

if [[ -f "$TEST_LOG_1" ]] && grep -q '"event":"session_start"' "$TEST_LOG_1"; then
    ok "SessionStart hook emitted session_start to ambient.jsonl"
else
    fail "SessionStart hook did not emit session_start (log: $(cat "$TEST_LOG_1" 2>/dev/null || echo '<missing>'))"
fi

# ── 2. PreToolUse hook does NOT emit session_start ───────────────────────────
echo "Test 2: PreToolUse hook does NOT emit session_start"
TEST_LOG_2="$TMP/ambient-2.jsonl"
CHUMP_SESSION_ID="test-infra-102-pretool" \
CHUMP_AMBIENT_LOG="$TEST_LOG_2" \
CHUMP_AMBIENT_INJECT=0 \
    "$INJECT" PreToolUse >/dev/null 2>&1 || true

if [[ ! -f "$TEST_LOG_2" ]] || ! grep -q '"event":"session_start"' "$TEST_LOG_2"; then
    ok "PreToolUse hook correctly did NOT emit session_start"
else
    fail "PreToolUse hook unexpectedly emitted session_start"
fi

# ── 3. CHUMP_AMBIENT_SESSION_START_EMIT=0 bypass works ──────────────────────
echo "Test 3: bypass env disables emit"
TEST_LOG_3="$TMP/ambient-3.jsonl"
CHUMP_SESSION_ID="test-infra-102-bypass" \
CHUMP_AMBIENT_LOG="$TEST_LOG_3" \
CHUMP_AMBIENT_INJECT=0 \
CHUMP_AMBIENT_SESSION_START_EMIT=0 \
    "$INJECT" SessionStart >/dev/null 2>&1 || true

if [[ ! -f "$TEST_LOG_3" ]] || ! grep -q '"event":"session_start"' "$TEST_LOG_3"; then
    ok "CHUMP_AMBIENT_SESSION_START_EMIT=0 disabled the emit"
else
    fail "bypass env was ignored (log: $(cat "$TEST_LOG_3"))"
fi

# ── 4. gap-claim.sh emit path: invoke ambient-emit.sh directly the same way ─
# We test the emit primitive that gap-claim.sh uses (avoids needing a real
# git worktree + lease setup for the test). The gap-claim.sh code path is
# trivially: `ambient-emit.sh session_start gap=$GAP_ID`.
echo "Test 4: ambient-emit.sh writes a schema-valid session_start row"
TEST_LOG_4="$TMP/ambient-4.jsonl"
CHUMP_SESSION_ID="test-infra-102-gapclaim" \
CHUMP_AMBIENT_LOG="$TEST_LOG_4" \
    "$EMIT" session_start "gap=INFRA-102" >/dev/null 2>&1 || true

if [[ -f "$TEST_LOG_4" ]] && grep -q '"event":"session_start"' "$TEST_LOG_4" \
        && grep -q '"gap":"INFRA-102"' "$TEST_LOG_4"; then
    ok "ambient-emit.sh wrote schema-valid session_start with gap field"
else
    fail "ambient-emit.sh did not write expected session_start (log: $(cat "$TEST_LOG_4" 2>/dev/null || echo '<missing>'))"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Summary ==="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "  failures:"
    for f in "${FAILS[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
