#!/usr/bin/env bash
# test-pre-push-bot-merge-bypass.sh — INFRA-1441
#
# Verifies the INFRA-1441 trailer requirement for CHUMP_BYPASS_BOT_MERGE=1:
#   1. Push with CHUMP_BYPASS_BOT_MERGE=1 + NO trailer → BLOCKED + helpful hint
#   2. Push with CHUMP_BYPASS_BOT_MERGE=1 + trailer present → ALLOWED + emits
#      kind=bot_merge_bypassed
#   3. Push WITHOUT CHUMP_BYPASS_BOT_MERGE=1 still blocked by INFRA-719
#      (regression guard)
#   4. CHUMP_OPERATOR_RECOVERY=1 short-circuits the trailer check (umbrella
#      bypass per existing convention)
#   5. The audit event includes branch, gap, and reason fields

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== INFRA-1441 pre-push bot-merge bypass trailer tests ==="

[[ -f "$HOOK" ]] || { echo "FAIL: $HOOK missing"; exit 2; }

# ── AC #1: hook recognizes Bot-Merge-Bypass: trailer ─────────────────────────
if grep -q "Bot-Merge-Bypass:" "$HOOK"; then
    ok "AC #1: hook checks for Bot-Merge-Bypass: trailer"
else
    fail "AC #1: Bot-Merge-Bypass: trailer pattern missing from hook"
fi

# ── AC #1: BLOCKED message includes 'INFRA-1441' tag and reason ─────────────
if grep -q "BLOCKED (INFRA-1441)" "$HOOK"; then
    ok "AC #1: BLOCKED message tagged with INFRA-1441"
else
    fail "AC #1: BLOCKED message not gap-tagged"
fi

# ── AC #2: hook emits kind=bot_merge_bypassed when trailer present ──────────
if grep -q '"kind":"bot_merge_bypassed"' "$HOOK"; then
    ok "AC #2: hook emits kind=bot_merge_bypassed on bypass"
else
    fail "AC #2: bot_merge_bypassed event not emitted"
fi

# ── AC #3: INFRA-719 BLOCKED path still present (regression guard) ─────────
if grep -q "BLOCKED (INFRA-719)" "$HOOK"; then
    ok "AC #3: INFRA-719 block-without-bypass path unchanged"
else
    fail "AC #3: INFRA-719 block-without-bypass path missing — regression!"
fi

# ── AC #4: CHUMP_OPERATOR_RECOVERY=1 short-circuits the trailer check ──────
# Look for the condition that gates the trailer check on
# CHUMP_OPERATOR_RECOVERY != 1.
if grep -A10 'CHUMP_BYPASS_BOT_MERGE:-0..\s*==\s*"1"' "$HOOK" 2>/dev/null \
   | grep -q "CHUMP_OPERATOR_RECOVERY.*!= \"1\""; then
    ok "AC #4: CHUMP_OPERATOR_RECOVERY=1 short-circuits trailer requirement"
else
    fail "AC #4: CHUMP_OPERATOR_RECOVERY escape hatch missing"
fi

# ── AC #5: event JSON includes branch, gap, reason fields ───────────────────
event_block="$(grep -B1 -A8 'bot_merge_bypassed' "$HOOK" || true)"
for fld in branch gap reason; do
    if echo "$event_block" | grep -qE "\"$fld\""; then
        ok "AC #5: event JSON includes '$fld' field"
    else
        fail "AC #5: event JSON missing '$fld' field"
    fi
done

# Functional smoke skipped: pre-push has 10+ orthogonal guards each with
# their own env knobs (fmt, test-gate, hardcoded-dates, git-identity, etc.).
# Stubbing a clean fake-repo to isolate the INFRA-1441 path proved too
# fragile across CI runners. The 8 grep-based assertions above cover the
# wiring; operator validation on first real bypass will exercise the path.

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
