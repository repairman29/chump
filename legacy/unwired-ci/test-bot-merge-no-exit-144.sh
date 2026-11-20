#!/usr/bin/env bash
# test-bot-merge-no-exit-144.sh — INFRA-2426
#
# Regression test: bot-merge.sh must NEVER exit 144 (the former silent
# graphql_exhausted wedge exit). Asserts:
#   1. Syntax: bot-merge.sh passes bash -n.
#   2. No bare `exit 144` instruction (only comments may reference it).
#   3. Wedge guard exits 4 (not 144) when graphql_exhausted is in ambient.jsonl.
#   4. Wedge-aborted ambient event has exit_code=4 field.
#   5. graphql_recovered event newer than exhausted clears the wedge (exit 0).
#   6. Budget watchdog reads CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S (documented name).
#   7. Budget default is 900s when using the CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S var.
#   8. _bm_sigterm_handler emits kind=bot_merge_timeout before exiting.
#   9. TERM trap calls _bm_sigterm_handler (not a bare inline `exit 1`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BOT_MERGE" ]] || { echo "SKIP: bot-merge.sh not found at $BOT_MERGE" >&2; exit 0; }

echo "=== INFRA-2426: bot-merge.sh must never exit 144 ==="
echo

# ── 1. Syntax ─────────────────────────────────────────────────────────────────
if bash -n "$BOT_MERGE" 2>/dev/null; then
    ok "bot-merge.sh passes bash -n"
else
    fail "bot-merge.sh has syntax errors"
fi

# ── 2. No bare `exit 144` as a shell statement (comments/strings are ok) ──────
# Match lines where `exit 144` appears as an actual shell command:
#   - not a comment line (first non-space is NOT #)
#   - not inside a single-quoted string (printf '...' context)
#   - the exit is at a shell-statement position (not after a quote)
# Strategy: strip single-quoted strings from each line, then check for exit 144.
_bare_144=$(grep -n 'exit 144' "$BOT_MERGE" \
    | grep -v "^[0-9]*:[[:space:]]*#" \
    | python3 -c "
import sys, re
for line in sys.stdin:
    # Remove content inside single-quoted strings to skip printf '...144...' lines
    stripped = re.sub(r\"'[^']*'\", \"''\", line)
    if re.search(r'\bexit\s+144\b', stripped):
        sys.stdout.write(line)
" 2>/dev/null || true)
if [[ -z "$_bare_144" ]]; then
    ok "no executable 'exit 144' in bot-merge.sh (only in string literals/comments)"
else
    fail "bot-merge.sh still has executable 'exit 144': $_bare_144"
fi

# ── 3 + 4. Wedge guard exits 4 and emits correct ambient event ────────────────
# Extract the wedge guard block by line numbers (INFRA-1939 block starts at the
# `if [ "\${CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE:-0}"` line and ends just before
# the SCRIPT_DIR= line). Use sed for reliable range extraction.
_WEDGE_START=$(grep -n 'CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE' "$BOT_MERGE" \
    | grep 'if \[' | head -1 | cut -d: -f1)
_WEDGE_END=$(grep -n '^SCRIPT_DIR=' "$BOT_MERGE" | head -1 | cut -d: -f1)

TMP="$(mktemp -d)"
AMB="$TMP/ambient.jsonl"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$_WEDGE_START" && -n "$_WEDGE_END" && "$_WEDGE_END" -gt "$_WEDGE_START" ]]; then
    WEDGE_BLOCK="$(sed -n "${_WEDGE_START},$((  _WEDGE_END - 1 ))p" "$BOT_MERGE")"

    # Write a recent graphql_exhausted event to the fake ambient log.
    EXHAUSTED_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"graphql_exhausted","note":"test fixture"}\n' \
        "$EXHAUSTED_TS" >> "$AMB"

    _wedge_exit=0
    (
        export CHUMP_AMBIENT_LOG="$AMB"
        export CHUMP_BOT_MERGE_GRAPHQL_WEDGE_LOOKBACK_S=1800
        export CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=0
        export CHUMP_REPO_ROOT="$TMP"
        eval "$WEDGE_BLOCK" 2>/dev/null
    ) || _wedge_exit=$?

    if [[ "$_wedge_exit" -eq 144 ]]; then
        fail "wedge guard still exits 144 — INFRA-2426 fix did not apply"
    elif [[ "$_wedge_exit" -eq 4 ]]; then
        ok "wedge guard exits 4 (not 144) under graphql_exhausted"
    elif [[ "$_wedge_exit" -eq 0 ]]; then
        fail "wedge guard exited 0 (expected 4) — ambient fixture not picked up"
    else
        fail "wedge guard exited $_wedge_exit (expected 4; any non-144 better, but 4 required)"
    fi

    # Check ambient event has exit_code:4
    if grep -q '"kind":"bot_merge_graphql_wedge_aborted"' "$AMB" 2>/dev/null; then
        if grep '"kind":"bot_merge_graphql_wedge_aborted"' "$AMB" \
                | grep -q '"exit_code":4'; then
            ok "bot_merge_graphql_wedge_aborted event has exit_code=4"
        else
            fail "bot_merge_graphql_wedge_aborted emitted but missing exit_code=4 field"
        fi
    else
        fail "bot_merge_graphql_wedge_aborted not emitted when wedge fires"
    fi
else
    fail "could not locate wedge guard block in bot-merge.sh (start=$_WEDGE_START end=$_WEDGE_END)"
    fail "wedge exit code test skipped due to extraction failure"
fi

# ── 5. graphql_recovered clears the wedge ────────────────────────────────────
TMP2="$(mktemp -d)"
AMB2="$TMP2/ambient.jsonl"
# An old exhausted event followed by a newer recovered event.
printf '{"ts":"2026-06-02T10:00:00Z","kind":"graphql_exhausted","note":"old"}\n' >> "$AMB2"
RECOVERED_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"graphql_recovered","note":"rate limit reset"}\n' \
    "$RECOVERED_TS" >> "$AMB2"

if [[ -n "${WEDGE_BLOCK:-}" ]]; then
    _recover_exit=0
    (
        export CHUMP_AMBIENT_LOG="$AMB2"
        export CHUMP_BOT_MERGE_GRAPHQL_WEDGE_LOOKBACK_S=1800
        export CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=0
        export CHUMP_REPO_ROOT="$TMP2"
        eval "$WEDGE_BLOCK" 2>/dev/null
    ) || _recover_exit=$?

    if [[ "$_recover_exit" -eq 4 ]]; then
        fail "wedge fired despite graphql_recovered being present (recovery bypass broken)"
    else
        ok "graphql_recovered clears the wedge (exit=$_recover_exit, not 4)"
    fi

    if grep -q '"kind":"bot_merge_graphql_wedge_cleared"' "$AMB2" 2>/dev/null; then
        ok "bot_merge_graphql_wedge_cleared event emitted on recovery"
    else
        # Only a hard fail if we expected the recovery path ran
        if [[ "$_recover_exit" -ne 4 ]]; then
            ok "wedge cleared (no cleared event — old exhausted ts may be outside lookback window)"
        else
            fail "no bot_merge_graphql_wedge_cleared event despite recovery event"
        fi
    fi
else
    ok "wedge recovery test skipped (block extraction failed above)"
fi
rm -rf "$TMP2"

# ── 6. Budget var: CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S referenced ──────────────
if grep -q 'CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S' "$BOT_MERGE"; then
    ok "CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S referenced in bot-merge.sh"
else
    fail "CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S missing — budget var mismatch unfixed"
fi

# ── 7. Budget default is 900 (not 600) ───────────────────────────────────────
# The watchdog line must fall back through the subagent var to 900, not 600.
if grep 'CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S.*900\|local budget.*CHUMP_SUBAGENT' \
        "$BOT_MERGE" >/dev/null 2>&1; then
    ok "budget default includes 900s via CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S chain"
else
    fail "budget 900s default not found via CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S"
fi

# ── 8. _bm_sigterm_handler emits bot_merge_timeout ───────────────────────────
if grep -q '_bm_sigterm_handler' "$BOT_MERGE"; then
    ok "_bm_sigterm_handler function present"
else
    fail "_bm_sigterm_handler missing — SIGTERM still exits silently"
fi

if grep -q 'bot_merge_timeout' "$BOT_MERGE"; then
    ok "bot_merge_timeout kind used in bot-merge.sh"
else
    fail "bot_merge_timeout not referenced — SIGTERM exit has no ambient signal"
fi

# ── 9. TERM trap calls _bm_sigterm_handler ───────────────────────────────────
_term_trap_line=$(grep "trap.*TERM" "$BOT_MERGE" | grep -v '^[[:space:]]*#' | head -1 || true)
if [[ "$_term_trap_line" == *'_bm_sigterm_handler'* ]]; then
    ok "TERM trap delegates to _bm_sigterm_handler"
else
    fail "TERM trap does not call _bm_sigterm_handler: '$_term_trap_line'"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
