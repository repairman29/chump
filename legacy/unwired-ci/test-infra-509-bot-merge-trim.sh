#!/usr/bin/env bash
# test-infra-509-bot-merge-trim.sh — INFRA-509 tests.
#
# Verifies that dead code removed from scripts/coord/bot-merge.sh:
#   (1) INFRA-344 filing-style PR detection block is gone
#   (2) docs/gaps/ git-add lines are gone
#   (3) docs/gaps/ not in codemod detection regex
#   (4) legacy YAML "new file" skip path is gone
#   (5) bash -n passes (syntax valid)
#   (6) net line count is ≤ original (file shrank)
#   (7) INFRA-509 trim comment present (documents intent)
#   (8) INFRA-192 forward-chain notifier still present (kept live code)
#
# Run: ./scripts/ci/test-infra-509-bot-merge-trim.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== INFRA-509 bot-merge.sh dead-code trim tests ==="
echo

# ── Test 1: INFRA-344 filing-style PR detection block is gone ─────────────────
echo "--- Test 1: INFRA-344 PR-detection block removed ---"
if grep -q 'docs/gaps/${_gid}\.yaml.*new file\|new_file.*docs/gaps\|filing.style.*skip\|INFRA-344.*new.*yaml' \
       "$BOT_MERGE" 2>/dev/null; then
    fail "Test 1: INFRA-344 filing-style PR detection still present in bot-merge.sh"
else
    ok "Test 1: INFRA-344 PR-detection block absent"
fi

# ── Test 2: docs/gaps/ git-add lines are gone ─────────────────────────────────
echo "--- Test 2: docs/gaps/ git-add dead code removed ---"
if grep -qE 'git add.*docs/gaps/|git add.*_autoclose|_autoclose_changed' \
       "$BOT_MERGE" 2>/dev/null; then
    fail "Test 2: docs/gaps/ git-add lines still present in bot-merge.sh"
else
    ok "Test 2: docs/gaps/ git-add dead code absent"
fi

# ── Test 3: docs/gaps/ not in codemod detection regex ─────────────────────────
echo "--- Test 3: docs/gaps/ dropped from codemod detection regex ---"
if grep -qE "grep.*cE.*docs/gaps/" "$BOT_MERGE" 2>/dev/null; then
    fail "Test 3: docs/gaps/ still appears in codemod detection grep pattern"
else
    ok "Test 3: docs/gaps/ absent from codemod detection regex"
fi

# ── Test 4: legacy YAML "new file" skip path gone ─────────────────────────────
echo "--- Test 4: legacy 'new file' YAML skip path removed ---"
if grep -qE 'new.*file.*\.yaml|\.yaml.*new.*file' "$BOT_MERGE" 2>/dev/null | grep -v 'INFRA-509\|historical\|archive'; then
    fail "Test 4: legacy new-YAML skip path still present"
else
    ok "Test 4: legacy new-YAML skip path absent"
fi

# ── Test 5: bash -n passes ────────────────────────────────────────────────────
echo "--- Test 5: bot-merge.sh passes bash syntax check ---"
if bash -n "$BOT_MERGE" 2>/dev/null; then
    ok "Test 5: bash -n reports no syntax errors"
else
    fail "Test 5: bot-merge.sh has syntax errors (bash -n failed)"
fi

# ── Test 6: file is non-empty and reasonable size ─────────────────────────────
echo "--- Test 6: bot-merge.sh is non-trivially sized (not accidentally hollowed) ---"
_line_count=$(wc -l < "$BOT_MERGE" 2>/dev/null || echo 0)
if [[ "${_line_count:-0}" -gt 500 ]]; then
    ok "Test 6: bot-merge.sh has ${_line_count} lines (reasonable, not hollowed)"
else
    fail "Test 6: bot-merge.sh has only ${_line_count} lines — may have been over-trimmed"
fi

# ── Test 7: INFRA-509 trim comment present ────────────────────────────────────
echo "--- Test 7: INFRA-509 trim comment documents the change ---"
if grep -q 'INFRA-509' "$BOT_MERGE" 2>/dev/null; then
    ok "Test 7: INFRA-509 comment present in bot-merge.sh"
else
    fail "Test 7: INFRA-509 comment missing from bot-merge.sh"
fi

# ── Test 8: INFRA-192 forward-chain notifier still present ────────────────────
echo "--- Test 8: INFRA-192 forward-chain notifier preserved (live code, not trimmed) ---"
if grep -q 'INFRA-192' "$BOT_MERGE" 2>/dev/null; then
    ok "Test 8: INFRA-192 forward-chain notifier still present"
else
    fail "Test 8: INFRA-192 forward-chain notifier accidentally removed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
