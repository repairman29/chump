#!/usr/bin/env bash
# test-bot-merge-chump-doctor-wrap.sh — INFRA-469 (supersedes INFRA-458)
#
# Verifies that:
#  1. chump_with_doctor wrapper is GONE from bot-merge.sh (redundant post-INFRA-469)
#  2. The two former call sites use plain `chump` (routed through bin/chump shim)
#  3. bin/chump shim exists and is executable

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"
SHIM="$REPO_ROOT/bin/chump"

[[ -f "$SCRIPT" ]] || { echo "FATAL: bot-merge.sh missing"; exit 2; }

echo "=== INFRA-469 shim replaces chump_with_doctor (bot-merge regression) ==="
echo

# --- Test 1: chump_with_doctor is deleted ---
if grep -q '^chump_with_doctor()' "$SCRIPT"; then
    fail "chump_with_doctor function still defined in bot-merge.sh (should be deleted — INFRA-469)"
else
    ok "chump_with_doctor wrapper removed from bot-merge.sh"
fi

# --- Test 2: no lingering chump_with_doctor call sites ---
if grep -qE 'chump_with_doctor' "$SCRIPT"; then
    fail "lingering chump_with_doctor references in bot-merge.sh:"
    grep -nE 'chump_with_doctor' "$SCRIPT" | sed 's/^/    /'
else
    ok "no chump_with_doctor references remain in bot-merge.sh"
fi

# --- Test 3: bin/chump shim exists and is executable ---
if [[ -x "$SHIM" ]]; then
    ok "bin/chump shim exists and is executable"
else
    fail "bin/chump shim missing or not executable at $SHIM"
fi

# --- Test 4: bot-merge.sh injects bin/ into PATH ---
if grep -qE 'PATH=.*\$REPO_ROOT/bin' "$SCRIPT"; then
    ok "bot-merge.sh prepends \$REPO_ROOT/bin to PATH (INFRA-469)"
else
    fail "bot-merge.sh does not inject \$REPO_ROOT/bin into PATH"
fi

# --- Test 5: former gap-ship call site uses plain chump ---
if grep -qE 'chump gap ship' "$SCRIPT"; then
    ok "gap ship call site uses plain chump"
else
    fail "gap ship call site not found in bot-merge.sh"
fi

# --- Test 6: former gap-list call site uses plain chump ---
if grep -qE 'chump gap list.*--status open.*--json' "$SCRIPT"; then
    ok "gap list call site uses plain chump"
else
    fail "gap list call site not found in bot-merge.sh"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
