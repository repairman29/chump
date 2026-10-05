#!/usr/bin/env bash
# test-bot-merge-autoclose-no-false-uncaught.sh — CREDIBLE-295
#
# Regression test: the auto-close-gap stage's `chump gap ship` call is
# deliberately wrapped in `set +e ... set -e` so a non-zero rc can be
# captured into `_autoclose_rc` and handled as a WARN (PR is already armed,
# see INFRA-1030) rather than killing bot-merge. But `set +e` does NOT
# suspend bash's `trap ... ERR` — only wrapping a command as the non-final
# member of a `||` list is exempt from both errexit and the ERR trap. So the
# RESILIENT-052 ERR trap (bot-merge.sh:397) fired on the very failure this
# region exists to handle, emitting a false kind=bot_merge_uncaught_error
# even though the rc is captured and handled — polluting the ambient signal
# and risking a false duty-officer trigger.
#
# The fix inlines `trap - ERR` / `trap "$_BM_ERR_TRAP_CMD" ERR` directly at
# the call site rather than via helper functions — bash saves/restores the
# ERR trap around every function call (unless `set -o functrace`), so a
# `trap - ERR` executed inside a called function silently reverts the
# instant that function returns, leaving the "suspend" a no-op. This test
# extracts the REAL handler + the REAL guarded block verbatim from
# bot-merge.sh and proves both that inline suspend works, AND that a
# function-wrapped suspend would NOT have (guards against reintroducing
# that exact footgun).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BOT_MERGE" ]] || { echo "SKIP: bot-merge.sh not found at $BOT_MERGE" >&2; exit 0; }

echo "=== CREDIBLE-295: auto-close-gap ship failure must not emit a false bot_merge_uncaught_error ==="
echo

# ── 1. The shared trap-command variable exists ────────────────────────────────
if grep -qE "^_BM_ERR_TRAP_CMD=" "$BOT_MERGE"; then
    ok "_BM_ERR_TRAP_CMD defined (reusable trap command string)"
else
    fail "_BM_ERR_TRAP_CMD missing"
fi

# ── 2. No function-wrapped ERR-trap suspend/resume reintroduced ──────────────
# (this exact pattern silently no-ops: the trap reverts when the function
# returns, per bash's per-function save/restore of DEBUG/RETURN/ERR traps.)
if grep -qE '^\s*_bm_err_trap_(suspend|resume)\s*\(\)' "$BOT_MERGE"; then
    fail "function-wrapped ERR-trap suspend/resume reintroduced — this pattern is a no-op in bash (trap reverts on function return)"
else
    ok "no function-wrapped ERR-trap suspend/resume helper present"
fi

# ── 3. The auto-close-gap ship call is bracketed by inline trap commands ─────
_SHIP_LINE=$(grep -n 'run_timed_hb "gap ship' "$BOT_MERGE" | head -1 | cut -d: -f1)
if [[ -n "$_SHIP_LINE" ]]; then
    _CTX="$(sed -n "$(( _SHIP_LINE - 6 )),$(( _SHIP_LINE + 8 ))p" "$BOT_MERGE")"
    if grep -qE '^\s*trap - ERR\s*$' <<<"$_CTX" && grep -q 'trap "\$_BM_ERR_TRAP_CMD" ERR' <<<"$_CTX"; then
        ok "chump gap ship call is bracketed by inline 'trap - ERR' / 'trap \"\$_BM_ERR_TRAP_CMD\" ERR'"
    else
        fail "chump gap ship call is NOT bracketed by the inline trap suspend/resume"
    fi
else
    fail "could not locate the 'run_timed_hb \"gap ship' call in bot-merge.sh"
fi

# ── 4. Extract the real handler + trap-cmd var, and the real guarded block ───
_HANDLER_START=$(grep -n '^_bm_err_handler() {' "$BOT_MERGE" | head -1 | cut -d: -f1)
_TRAP_LINE=$(grep -n '^_BM_ERR_TRAP_CMD=' "$BOT_MERGE" | head -1 | cut -d: -f1)

if [[ -z "$_HANDLER_START" || -z "$_TRAP_LINE" ]]; then
    fail "could not locate handler/trap-var block bounds"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# handler function body through the _BM_ERR_TRAP_CMD assignment (which sits
# right after the initial `trap '_bm_err_handler ...' ERR` registration).
HANDLER_BLOCK="$(sed -n "${_HANDLER_START},${_TRAP_LINE}p" "$BOT_MERGE")"

if ! grep -q '_BM_ERR_TRAP_CMD=' <<<"$HANDLER_BLOCK"; then
    fail "extracted handler block missing _BM_ERR_TRAP_CMD assignment — extraction bounds wrong"
fi

# The exact guarded ship block, extracted verbatim from the real call site.
_BLOCK_START=$(( _SHIP_LINE - 6 ))
_BLOCK_END=$(( _SHIP_LINE + 8 ))
SHIP_BLOCK_RAW="$(sed -n "${_BLOCK_START},${_BLOCK_END}p" "$BOT_MERGE")"
# Replace the loop variables with fixed test values so it runs standalone.
SHIP_BLOCK="${SHIP_BLOCK_RAW//\$_gid/CREDIBLE-295-TEST}"
SHIP_BLOCK="${SHIP_BLOCK//\$TARGET_PR/1}"

if ! grep -q 'trap - ERR' <<<"$SHIP_BLOCK" || ! grep -q '_autoclose_rc=\$?' <<<"$SHIP_BLOCK"; then
    fail "extracted ship block missing expected lines — extraction bounds wrong: $SHIP_BLOCK"
fi

TMP="$(mktemp -d)"
AMB="$TMP/ambient.jsonl"
BINDIR="$TMP/bin"
mkdir -p "$BINDIR"
trap 'rm -rf "$TMP"' EXIT

# Stub `chump` that always fails — stands in for a transient `chump gap ship`
# failure (state.db lock contention, etc.) after the PR is already armed.
cat > "$BINDIR/chump" <<'EOF'
#!/usr/bin/env bash
echo "chump: simulated gap-ship failure" >&2
exit 1
EOF
chmod +x "$BINDIR/chump"

run_scenario() {
    local out_file="$1" amb_file="$2" ship_block="$3"
    local harness="$TMP/harness_$$_$RANDOM.sh"
    {
        echo 'set -euo pipefail'
        printf '%s\n' "$HANDLER_BLOCK"
        echo "export CHUMP_AMBIENT_LOG='$amb_file'"
        echo 'GAP_IDS=(CREDIBLE-295-TEST)'
        echo "export REPO_ROOT='$TMP'"
        echo "export PATH=\"$BINDIR:\$PATH\""
        echo '__STAGE_LABEL="auto-close gap CREDIBLE-295-TEST via PR #1 (INFRA-154)"'
        # run_timed_hb stub: mirrors the real signature (label, timeout, cmd...).
        echo 'run_timed_hb() { shift 2; "$@"; }'
        echo '_autoclose_main_repo="."'
        echo '_autoclose_chump="chump"'
        printf '%s\n' "$ship_block"
        echo 'echo "CAPTURED_RC=$_autoclose_rc"'
    } > "$harness"
    local rc=0
    bash "$harness" >"$out_file" 2>&1 || rc=$?
    return "$rc"
}

# ── 5. Real (fixed) block: no false event, failure still captured ────────────
OUT="$TMP/stdout.log"
_test_exit=0
run_scenario "$OUT" "$AMB" "$SHIP_BLOCK" || _test_exit=$?

if [[ "$_test_exit" -eq 0 ]]; then
    ok "harness completed (guarded region did not propagate the ship failure as a script death)"
else
    fail "harness exited non-zero ($_test_exit) — guarded region let the failure escape: $(cat "$OUT")"
fi

if grep -q 'CAPTURED_RC=1' "$OUT" 2>/dev/null; then
    ok "the ship failure IS still captured into _autoclose_rc (existing WARN path unaffected)"
else
    fail "ship failure was not captured into _autoclose_rc: $(cat "$OUT")"
fi

if [[ ! -s "$AMB" ]] || ! grep -q '"kind":"bot_merge_uncaught_error"' "$AMB" 2>/dev/null; then
    ok "ZERO bot_merge_uncaught_error emitted for the handled auto-close-gap ship failure"
else
    fail "false bot_merge_uncaught_error emitted: $(cat "$AMB")"
fi

# ── 6. Negative control: same scenario MINUS the trap suspend DOES fire it ───
# Proves this test actually exercises the bug class (fails without the fix).
OLD_SHIP_BLOCK="$(grep -v -E 'trap - ERR|trap "\$_BM_ERR_TRAP_CMD" ERR' <<<"$SHIP_BLOCK")"
AMB_OLD="$TMP/ambient_old.jsonl"
run_scenario "$TMP/stdout_old.log" "$AMB_OLD" "$OLD_SHIP_BLOCK" || true

if [[ -s "$AMB_OLD" ]] && grep -q '"kind":"bot_merge_uncaught_error"' "$AMB_OLD" 2>/dev/null; then
    ok "negative control confirms: WITHOUT the trap suspend, the same failure DOES emit a false event"
else
    fail "negative control did not reproduce the bug — this test would not have caught a regression"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
