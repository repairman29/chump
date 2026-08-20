#!/usr/bin/env bash
# test-bot-merge-err-trap-loud-fail.sh — RESILIENT-052
#
# Regression test: bot-merge.sh must never let a `set -e` death (e.g. a `gh`
# sub-process crashing with SIGURG, exit 128+16=144 — INFRA-2688) exit
# silently. Reproduces the exit-144 condition against the real ERR-trap
# handler extracted from bot-merge.sh and asserts a loud, diagnosable
# failure: the failing step, the exit code, the signal name (when the exit
# code encodes one), and an ambient kind=bot_merge_uncaught_error event.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BOT_MERGE" ]] || { echo "SKIP: bot-merge.sh not found at $BOT_MERGE" >&2; exit 0; }

echo "=== RESILIENT-052: bot-merge.sh ERR trap must turn silent set -e deaths loud ==="
echo

# ── 1. Syntax ─────────────────────────────────────────────────────────────────
if bash -n "$BOT_MERGE" 2>/dev/null; then
    ok "bot-merge.sh passes bash -n"
else
    fail "bot-merge.sh has syntax errors"
fi

# ── 2. An ERR trap is actually registered ─────────────────────────────────────
if grep -qE "^trap '_bm_err_handler .*' ERR" "$BOT_MERGE"; then
    ok "ERR trap registered (delegates to _bm_err_handler)"
else
    fail "no 'trap ... ERR' registered in bot-merge.sh — set -e deaths still silent"
fi

# ── 3. Extract the real _bm_err_handler function + its trap registration ─────
_HANDLER_START=$(grep -n '^_bm_err_handler() {' "$BOT_MERGE" | head -1 | cut -d: -f1)
_HANDLER_END=$(grep -n "^trap '_bm_err_handler" "$BOT_MERGE" | head -1 | cut -d: -f1)

if [[ -z "$_HANDLER_START" || -z "$_HANDLER_END" || "$_HANDLER_END" -lt "$_HANDLER_START" ]]; then
    fail "could not locate _bm_err_handler block (start=$_HANDLER_START end=$_HANDLER_END)"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

HANDLER_BLOCK="$(sed -n "${_HANDLER_START},${_HANDLER_END}p" "$BOT_MERGE")"

# ── 4. Reproduce the exit-144 condition: a child process dies on SIGURG ──────
# (kill -l 16 == SIGURG on macOS/BSD, SIGSTKFLT on Linux — the number 144 is
# what matters, not the platform-specific name INFRA-2688 guessed at.)
TMP="$(mktemp -d)"
AMB="$TMP/ambient.jsonl"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stderr.log"
HARNESS="$TMP/harness.sh"
{
    echo 'set -euo pipefail'
    printf '%s\n' "$HANDLER_BLOCK"
    echo "export CHUMP_AMBIENT_LOG='$AMB'"
    echo 'GAP_IDS=(RESILIENT-052-TEST)'
    echo "export REPO_ROOT='$TMP'"
    echo '__STAGE_LABEL="cargo test suite"'
    # Simulate the real-world trigger: a subprocess (standing in for a `gh`
    # sub-process) killed by signal 16, exit code 128+16=144 — propagated
    # straight through `set -e` exactly as bot-merge.sh's real body would.
    echo "bash -c 'exit 144'"
} > "$HARNESS"

# Run as a genuinely separate top-level bash process (not an inline `( ... )`
# subshell of THIS script) so `set -e` actually governs it end-to-end — a
# subshell nested inside a caller's own conditional/test context can have
# `errexit` silently neutered by POSIX inheritance rules, which would make
# this test pass/fail on the harness's shell nesting instead of the real fix.
_test_exit=0
bash "$HARNESS" 2>"$OUT" || _test_exit=$?

if [[ "$_test_exit" -eq 144 ]]; then
    ok "exit-144 condition reproduced (child exit propagated through set -e)"
else
    fail "did not reproduce exit 144 (got $_test_exit) — harness broken, not the fix"
fi

if grep -q "UNCAUGHT FAILURE" "$OUT" 2>/dev/null; then
    ok "loud diagnostic printed to stderr on the exit-144 death"
else
    fail "no loud diagnostic on stderr — set -e death is still silent: $(cat "$OUT" 2>/dev/null)"
fi

if grep -q 'exit_code=144' "$OUT" 2>/dev/null; then
    ok "stderr diagnostic includes the actual exit code (144)"
else
    fail "stderr diagnostic missing exit_code=144"
fi

if grep -q 'step="cargo test suite"' "$OUT" 2>/dev/null; then
    ok "stderr diagnostic names the in-flight step"
else
    fail "stderr diagnostic does not name the failing step"
fi

if grep -q 'signal=' "$OUT" 2>/dev/null; then
    ok "stderr diagnostic decodes the signal encoded in the exit code (rc>128)"
else
    fail "stderr diagnostic did not decode the signal for exit_code=144"
fi

# ── 5. Ambient event emitted for fleet monitors ───────────────────────────────
if [[ -f "$AMB" ]] && grep -q '"kind":"bot_merge_uncaught_error"' "$AMB" 2>/dev/null; then
    ok "kind=bot_merge_uncaught_error emitted to ambient"
    if grep '"kind":"bot_merge_uncaught_error"' "$AMB" | grep -q '"exit_code":144'; then
        ok "ambient event carries exit_code:144"
    else
        fail "ambient event missing exit_code:144"
    fi
else
    fail "no bot_merge_uncaught_error event written to ambient — fleet monitors blind to this death"
fi

# ── 6. No bare `exit 144` reintroduced (still guarded, INFRA-2426) ───────────
_bare_144=$(grep -n 'exit 144' "$BOT_MERGE" \
    | grep -v "^[0-9]*:[[:space:]]*#" \
    | python3 -c "
import sys, re
for line in sys.stdin:
    stripped = re.sub(r\"'[^']*'\", \"''\", line)
    if re.search(r'\bexit\s+144\b', stripped):
        sys.stdout.write(line)
" 2>/dev/null || true)
if [[ -z "$_bare_144" ]]; then
    ok "no executable 'exit 144' in bot-merge.sh"
else
    fail "bot-merge.sh has executable 'exit 144': $_bare_144"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
