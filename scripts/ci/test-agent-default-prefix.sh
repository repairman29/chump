#!/usr/bin/env bash
# test-agent-default-prefix.sh — verify META-028 subagent default briefing.
#
# Checks:
#   1. SUBAGENT_DEFAULT_BRIEFING.md exists at the default path
#   2. The file contains the shipping-epilogue substring
#   3. get-agent-briefing-prefix.sh returns the correct path
#   4. CHUMP_AGENT_DEFAULT_PREFIX override is respected
#   5. A synthesized prompt that prepends the prefix contains the epilogue
#
# Exit: 0 = all checks pass, 1 = failure

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_PREFIX="$REPO_ROOT/docs/process/SUBAGENT_DEFAULT_BRIEFING.md"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# ── Test 1: default prefix file exists ───────────────────────────────────────
if [[ -f "$DEFAULT_PREFIX" ]]; then
    pass "SUBAGENT_DEFAULT_BRIEFING.md exists"
else
    fail "SUBAGENT_DEFAULT_BRIEFING.md not found at $DEFAULT_PREFIX"
fi

# ── Test 2: shipping epilogue substring present ───────────────────────────────
EPILOGUE_MARKER="bot-merge.sh --gap"
if grep -q "$EPILOGUE_MARKER" "$DEFAULT_PREFIX"; then
    pass "Shipping epilogue marker found in prefix file"
else
    fail "Shipping epilogue marker ('$EPILOGUE_MARKER') missing from $DEFAULT_PREFIX"
fi

# ── Test 3: get-agent-briefing-prefix.sh returns correct path ────────────────
RETURNED="$(bash "$REPO_ROOT/scripts/lib/get-agent-briefing-prefix.sh")"
if [[ "$RETURNED" == "$DEFAULT_PREFIX" ]]; then
    pass "get-agent-briefing-prefix.sh returns default path"
else
    fail "get-agent-briefing-prefix.sh returned '$RETURNED', expected '$DEFAULT_PREFIX'"
fi

# ── Test 4: CHUMP_AGENT_DEFAULT_PREFIX override respected ────────────────────
CUSTOM_PREFIX="$(mktemp -t test-prefix.XXXXXX)"
printf '## Custom prefix\nbot-merge.sh --gap CUSTOM-001 --auto-merge\n' > "$CUSTOM_PREFIX"
RETURNED_CUSTOM="$(CHUMP_AGENT_DEFAULT_PREFIX="$CUSTOM_PREFIX" bash "$REPO_ROOT/scripts/lib/get-agent-briefing-prefix.sh")"
rm -f "$CUSTOM_PREFIX"
if [[ "$RETURNED_CUSTOM" == "$CUSTOM_PREFIX" ]]; then
    pass "CHUMP_AGENT_DEFAULT_PREFIX override respected"
else
    fail "Override not respected: got '$RETURNED_CUSTOM', expected '$CUSTOM_PREFIX'"
fi

# ── Test 5: synthesized prompt includes the epilogue ─────────────────────────
SYNTHESIZED="$(cat "$DEFAULT_PREFIX")

---

Task: implement gap EVAL-999"
if echo "$SYNTHESIZED" | grep -q "$EPILOGUE_MARKER"; then
    pass "Synthesized prompt includes shipping-epilogue substring"
else
    fail "Synthesized prompt missing shipping-epilogue substring"
fi

echo ""
echo "All META-028 subagent-default-prefix checks passed."
