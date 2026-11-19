#!/usr/bin/env bash
# test-subagent-epilogue-budget-language.sh — META-027
# Greps SUBAGENT_DISPATCH.md and CLAUDE.md for required budget language tokens.
# Fails if the tokens drift (e.g. someone softens the STOP mandate).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$REPO_ROOT/docs/process/SUBAGENT_DISPATCH.md"
CLAUDE="$REPO_ROOT/CLAUDE.md"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOC" ]]    || fail "SUBAGENT_DISPATCH.md missing at $DOC"
[[ -f "$CLAUDE" ]] || fail "CLAUDE.md missing at $CLAUDE"

# ── SUBAGENT_DISPATCH.md tokens ───────────────────────────────────────────────
grep -q 'STOP' "$DOC" \
    || fail "SUBAGENT_DISPATCH.md missing 'STOP' mandate"
pass "SUBAGENT_DISPATCH.md contains 'STOP'"

grep -q 'wall-clock' "$DOC" \
    || fail "SUBAGENT_DISPATCH.md missing 'wall-clock' language"
pass "SUBAGENT_DISPATCH.md contains 'wall-clock'"

grep -qE '(900|CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S)' "$DOC" \
    || fail "SUBAGENT_DISPATCH.md missing budget value (900 or env var name)"
pass "SUBAGENT_DISPATCH.md contains budget number/var"

grep -q 'do not wait' "$DOC" \
    || fail "SUBAGENT_DISPATCH.md missing 'do not wait' directive"
pass "SUBAGENT_DISPATCH.md contains 'do not wait' directive"

# ── CLAUDE.md tokens ─────────────────────────────────────────────────────────
grep -q 'Spawning subagents' "$CLAUDE" \
    || fail "CLAUDE.md missing 'Spawning subagents' section"
pass "CLAUDE.md contains 'Spawning subagents' section"

grep -q 'CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S' "$CLAUDE" \
    || fail "CLAUDE.md missing CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S reference"
pass "CLAUDE.md references CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S"

printf '\nAll tests passed.\n'
