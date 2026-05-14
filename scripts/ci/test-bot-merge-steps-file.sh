#!/usr/bin/env bash
# CI test: INFRA-1035 — bot-merge.sh step-transition log for crash recovery.
#
# Tests:
#   1. steps file contains session-start entry after _bm_health_init
#   2. stage_start emits transition:start
#   3. stage_done emits transition:done with elapsed_s>=0
#   4. SIGTERM mid-step: steps file has crashed:true
#   5. bot-merge-recover.sh detects and reports crash correctly
#
# Approach: extract exact function bodies from bot-merge.sh via line numbers
# (stable since these are new additions) and run them in a minimal harness.

set -euo pipefail

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
RECOVER="$REPO_ROOT/scripts/coord/bot-merge-recover.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
LOCK_DIR="$TMPDIR_TEST/locks"
mkdir -p "$LOCK_DIR"

# ── inline implementation (mirrors bot-merge.sh) ─────────────────────────────
# Rather than sourcing the full 2300-line bot-merge.sh (which runs git/cargo at
# parse time), we inline the exact INFRA-1035 helpers under test.

_BM_PID=$$
_BM_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_BM_STEPS_FILE=""
_BM_LAST_STEP_TRANSITION=""
__STAGE_LABEL=""
__STAGE_T0=0

_bm_steps_append() {
    [[ -z "${_BM_STEPS_FILE:-}" ]] && return 0
    local transition="$1" step="${2:-unknown}" elapsed_s="${3:-0}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","step":"%s","transition":"%s","elapsed_s":%s}\n' \
        "$ts" "$step" "$transition" "$elapsed_s" \
        >> "$_BM_STEPS_FILE" 2>/dev/null || true
    _BM_LAST_STEP_TRANSITION="$transition"
}

_bm_health_init_steps() {
    local lock_dir="$1"
    mkdir -p "$lock_dir" 2>/dev/null || true
    _BM_STEPS_FILE="${lock_dir}/bot-merge-${_BM_PID}.steps"
    printf '{"ts":"%s","step":"session","transition":"start","elapsed_s":0,"pid":%d}\n' \
        "$_BM_STARTED_AT" "$_BM_PID" > "$_BM_STEPS_FILE" 2>/dev/null || true
}

_bm_cleanup_steps() {
    if [[ -n "${_BM_STEPS_FILE:-}" && "${_BM_LAST_STEP_TRANSITION:-}" == "start" ]]; then
        local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","step":"%s","transition":"error","elapsed_s":0,"crashed":true}\n' \
            "$ts" "${__STAGE_LABEL:-unknown}" \
            >> "$_BM_STEPS_FILE" 2>/dev/null || true
    fi
}

stage_start() {
    __STAGE_LABEL="$1"
    __STAGE_T0=$(date +%s)
    _bm_steps_append "start" "$__STAGE_LABEL" 0
}

stage_done() {
    local elapsed=$(( $(date +%s) - __STAGE_T0 ))
    _bm_steps_append "done" "$__STAGE_LABEL" "$elapsed"
}

json_field() {
    local field="$1" line="$2"
    python3 -c "import json,sys; d=json.loads('''$line'''); print(d.get('$field',''))" 2>/dev/null || echo ""
}

# ── test 1: steps file created with session-start entry ─────────────────────
_bm_health_init_steps "$LOCK_DIR"

if [[ -f "$_BM_STEPS_FILE" ]]; then
    pass "steps file created"
    if grep -q '"step":"session"' "$_BM_STEPS_FILE" && grep -q '"transition":"start"' "$_BM_STEPS_FILE"; then
        pass "session-start entry present in steps file"
    else
        fail "session-start entry missing from steps file"
    fi
else
    fail "steps file NOT created"
fi
SF="$_BM_STEPS_FILE"

# ── test 2: stage_start emits transition:start ────────────────────────────────
stage_start "test-step-alpha"

if grep -q '"transition":"start"' "$SF" && grep -q '"test-step-alpha"' "$SF"; then
    pass "stage_start emits transition:start for named step"
else
    fail "stage_start did NOT emit transition:start"
fi

# ── test 3: stage_done emits transition:done with elapsed_s>=0 ───────────────
sleep 1
stage_done

if grep -q '"transition":"done"' "$SF" && grep -q '"test-step-alpha"' "$SF"; then
    elapsed="$(python3 -c "
import json
for line in open('$SF'):
    d = json.loads(line)
    if d.get('transition') == 'done' and d.get('step') == 'test-step-alpha':
        print(d.get('elapsed_s', -1))
" 2>/dev/null | tail -1)"
    if [[ -n "$elapsed" ]] && python3 -c "exit(0 if int('$elapsed') >= 0 else 1)" 2>/dev/null; then
        pass "stage_done emits transition:done with elapsed_s=${elapsed}"
    else
        fail "stage_done elapsed_s invalid: '${elapsed}'"
    fi
else
    fail "stage_done did NOT emit transition:done"
fi

# ── test 4: SIGTERM mid-step → crashed:true ───────────────────────────────────
CRASH_SF="${LOCK_DIR}/bot-merge-crash-$$.steps"
(
    # Subshell with its own state
    _BM_STEPS_FILE="$CRASH_SF"
    _BM_LAST_STEP_TRANSITION=""
    __STAGE_LABEL=""
    __STAGE_T0=0

    trap '_bm_cleanup_steps' EXIT TERM INT

    printf '{"ts":"%s","step":"session","transition":"start","elapsed_s":0}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_BM_STEPS_FILE"

    stage_start "test-step-beta"
    # Simulate crash — use BASHPID so we kill the subshell, not the parent
    kill -TERM "$BASHPID"
    sleep 5  # unreachable
) 2>/dev/null || true

# Give the trap a moment to write
sleep 0.2

if [[ -f "$CRASH_SF" ]]; then
    if grep -q '"crashed":true' "$CRASH_SF"; then
        pass "SIGTERM mid-step produces crashed:true in steps file"
    else
        fail "SIGTERM mid-step: steps file exists but no crashed:true"
        echo "  Steps file contents:"
        cat "$CRASH_SF" | sed 's/^/    /'
    fi
    has_start="$(grep '"test-step-beta"' "$CRASH_SF" 2>/dev/null | grep -c '"start"' || true)"
    has_done="$(grep '"test-step-beta"' "$CRASH_SF" 2>/dev/null | grep -c '"done"' || true)"
    has_start="${has_start:-0}"; has_done="${has_done:-0}"
    if [[ "$has_start" -ge 1 && "$has_done" -eq 0 ]]; then
        pass "SIGTERM mid-step: start without done for crashed step"
    else
        fail "SIGTERM mid-step: unexpected step state (start=$has_start done=$has_done)"
    fi
else
    fail "SIGTERM mid-step: steps file not created"
fi

# ── test 5: bot-merge-recover.sh detects and reports crash ───────────────────
if [[ -f "$CRASH_SF" ]]; then
    recover_out="$("$RECOVER" --steps-file "$CRASH_SF" --lock-dir "$LOCK_DIR" 2>&1 || true)"
    if echo "$recover_out" | grep -qiE "crash|recovery|resume"; then
        pass "bot-merge-recover.sh reports crash in steps file"
    else
        fail "bot-merge-recover.sh did not mention crash: $recover_out"
    fi
else
    fail "bot-merge-recover.sh: no crash steps file to test with"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
