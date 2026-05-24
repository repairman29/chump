#!/usr/bin/env bash
# test-voice-banlist-self-fixture.sh — CREDIBLE-075
#
# Self-fixture smoke test: verifies that test-voice-banlist.sh does NOT
# self-flag docs/process/VOICE_GUARDRAIL.md (which necessarily contains
# banned words as definitional table examples).
#
# Precedent: INFRA-1728 #2509 was stuck 49min because the gate flagged its
# own guardrail doc on first merge. This test asserts the self-exclusion
# holds after every future change to the lint script.
#
# Usage: bash scripts/ci/test-voice-banlist-self-fixture.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BANLIST="$REPO_ROOT/scripts/ci/test-voice-banlist.sh"
GUARDRAIL="$REPO_ROOT/docs/process/VOICE_GUARDRAIL.md"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Guard: skip gracefully if INFRA-1728 hasn't landed yet ───────────────────
# test-voice-banlist.sh is added by INFRA-1728; before that PR merges, this
# self-fixture has nothing to test. Skip rather than fail so CREDIBLE-075 CI
# passes while INFRA-1728 is in-flight.
if [[ ! -f "$BANLIST" ]]; then
    echo "SKIP: test-voice-banlist.sh not yet on this branch (INFRA-1728 pending merge)"
    echo "  This self-fixture activates once INFRA-1728 merges into main."
    exit 0
fi

# ── Test 1: banlist script is present and executable ─────────────────────────
echo "Test 1: test-voice-banlist.sh is executable"
if [[ -x "$BANLIST" ]]; then
    ok "test-voice-banlist.sh is executable"
else
    fail "test-voice-banlist.sh missing or not executable: $BANLIST"
fi

# ── Test 2: VOICE_GUARDRAIL.md exists ────────────────────────────────────────
echo "Test 2: VOICE_GUARDRAIL.md exists"
if [[ -f "$GUARDRAIL" ]]; then
    ok "VOICE_GUARDRAIL.md exists"
else
    fail "VOICE_GUARDRAIL.md missing: $GUARDRAIL"
fi

# ── Test 3: guardrail doc actually contains banned words ─────────────────────
# Confirms the exclusion is load-bearing; if the doc is later sanitised this
# test reminds maintainers to reconsider whether the exclusion is still needed.
echo "Test 3: VOICE_GUARDRAIL.md contains banned words (exclusion is load-bearing)"
if grep -qiE '\b(revolutionary|world-class|leverage|unleash)\b' "$GUARDRAIL" 2>/dev/null; then
    ok "VOICE_GUARDRAIL.md contains banned words — exclusion is load-bearing"
else
    fail "VOICE_GUARDRAIL.md has no banned words — exclusion may be stale (review CREDIBLE-075)"
fi

# ── Test 4: banlist script contains the self-exclusion pattern ───────────────
echo "Test 4: banlist script excludes VOICE_GUARDRAIL.md from changed-file scan"
if grep -qF 'VOICE_GUARDRAIL' "$BANLIST" 2>/dev/null; then
    ok "banlist script references VOICE_GUARDRAIL.md exclusion"
else
    fail "banlist script missing VOICE_GUARDRAIL.md exclusion — self-flag will recur"
fi

# ── Test 5: base-ref double-prefix fix is present ────────────────────────────
echo "Test 5: --base=origin/main double-prefix bug is fixed"
if grep -qE '\[\[.*BASE_BRANCH.*==.*\*\/\*.*\]\]' "$BANLIST" 2>/dev/null || \
   grep -qE 'already.*slash|double.*prefix|BASE_BRANCH.*\*\/\*' "$BANLIST" 2>/dev/null; then
    ok "base-ref double-prefix guard present"
else
    fail "base-ref double-prefix guard missing — --base=origin/main falls back to HEAD~1"
fi

# ── Test 6: bypass trailer is documented in the script ───────────────────────
echo "Test 6: Voice-Lint-Bypass trailer is documented"
if grep -q 'Voice-Lint-Bypass' "$BANLIST" 2>/dev/null; then
    ok "Voice-Lint-Bypass bypass trailer documented"
else
    fail "Voice-Lint-Bypass bypass trailer missing from banlist script"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL: voice-banlist self-fixture requirements not met"
    exit 1
fi
echo "PASS: voice-banlist self-fixture satisfied"
exit 0
