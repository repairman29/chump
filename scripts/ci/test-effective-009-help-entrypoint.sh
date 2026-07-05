#!/usr/bin/env bash
# test-effective-009-help-entrypoint.sh — EFFECTIVE-009 tests.
#
# Verifies CLI entry-point redesign: chump with no args (or "help") shows
# grouped help text instead of dropping into agent/chat mode.
#
#   (1) print_help() function defined in src/main.rs
#   (2) no-args guard: args.len()==1 → print_help() and exit
#   (3) "chump help" guard wired (args.get(1)==Some("help"))
#   (4) "--help" / "-h" flags also trigger help
#   (5) First help line is "chump — gap orchestration tool"
#   (6) Help text contains expected command groups: gap, fleet, analytics, session
#   (7) Agent/chat fallthrough NOT reached when no args (guard placed correctly)
#   (8) chump orchestrate still reachable (help guard does not swallow it)
#
# Run: ./scripts/ci/test-effective-009-help-entrypoint.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAIN_RS="$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"

echo "=== EFFECTIVE-009 CLI help entry-point tests ==="
echo

# ── Test 1: print_help() function defined ────────────────────────────────────
echo "--- Test 1: print_help() function exists in src/main.rs ---"
if grep -q 'fn print_help()' "$MAIN_RS" 2>/dev/null; then
    ok "Test 1: print_help() defined in src/main.rs"
else
    fail "Test 1: print_help() not found in src/main.rs"
fi

# ── Test 2: no-args guard (args.len() == 1) ──────────────────────────────────
echo "--- Test 2: no-args guard present (args.len() == 1) ---"
if grep -q 'args\.len() == 1' "$MAIN_RS" 2>/dev/null; then
    ok "Test 2: args.len() == 1 guard present"
else
    fail "Test 2: args.len() == 1 guard missing"
fi

# ── Test 3: "chump help" guard ───────────────────────────────────────────────
echo "--- Test 3: 'chump help' subcommand guard wired ---"
if grep -q '"help"' "$MAIN_RS" 2>/dev/null && \
   grep -q 'wants_help\|Some("help")' "$MAIN_RS" 2>/dev/null; then
    ok "Test 3: 'help' subcommand guard present"
else
    fail "Test 3: 'help' subcommand guard missing"
fi

# ── Test 4: --help and -h flags ──────────────────────────────────────────────
echo "--- Test 4: --help and -h flags also trigger help ---"
if grep -q '"--help"' "$MAIN_RS" 2>/dev/null && \
   grep -q '"-h"' "$MAIN_RS" 2>/dev/null; then
    ok "Test 4: --help and -h flags wired"
else
    fail "Test 4: --help or -h flag missing"
fi

# ── Test 5: first help line is "chump — gap orchestration tool" ──────────────
echo "--- Test 5: first help line is 'chump — gap orchestration tool' ---"
if grep -q 'chump.*gap orchestration tool' "$MAIN_RS" 2>/dev/null; then
    ok "Test 5: 'chump — gap orchestration tool' headline present"
else
    fail "Test 5: headline 'chump — gap orchestration tool' missing from print_help()"
fi

# ── Test 6: expected command groups in help text ─────────────────────────────
echo "--- Test 6: help text has GAP MANAGEMENT, FLEET, ANALYTICS, SESSION groups ---"
_groups_ok=1
for grp in "GAP MANAGEMENT" "FLEET" "ANALYTICS" "SESSION"; do
    if ! grep -q "$grp" "$MAIN_RS" 2>/dev/null; then
        _groups_ok=0
        echo "    missing group: $grp"
    fi
done
if [[ "$_groups_ok" == "1" ]]; then
    ok "Test 6: all command groups present in print_help()"
else
    fail "Test 6: one or more command groups missing from print_help()"
fi

# ── Test 7: guard placed before the interactive agent fallthrough ─────────────
echo "--- Test 7: help guard placed before interactive chat fallthrough ---"
_help_line=$(grep -n 'wants_help\|args\.len() == 1' "$MAIN_RS" 2>/dev/null | head -1 | cut -d: -f1)
_chat_line=$(grep -n 'Chat with the agent\|interactive mode' "$MAIN_RS" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "$_help_line" && -n "$_chat_line" && "$_help_line" -lt "$_chat_line" ]]; then
    ok "Test 7: help guard (line $_help_line) precedes interactive fallthrough (line $_chat_line)"
else
    fail "Test 7: help guard not placed before interactive chat (help=$_help_line chat=$_chat_line)"
fi

# ── Test 8: orchestrate command is not blocked by the help guard ──────────────
echo "--- Test 8: 'orchestrate' handler still reachable after help guard ---"
# The help guard only fires when args.len()==1 or arg=="help"/"--help"/"-h".
# The orchestrate check should appear AFTER the help guard in the source.
_orch_line=$(grep -n 'Some("orchestrate")' "$MAIN_RS" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "$_help_line" && -n "$_orch_line" && "$_help_line" -lt "$_orch_line" ]]; then
    ok "Test 8: orchestrate handler (line $_orch_line) reachable after help guard"
else
    fail "Test 8: orchestrate handler not found or ordered incorrectly"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
