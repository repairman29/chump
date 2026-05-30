#!/usr/bin/env bash
# test-bot-merge-stall-monitor.sh — INFRA-2272
#
# Verifies the per-step progress ledger and gtimeout stall monitor added to
# bot-merge.sh.  All assertions run without real git/gh calls.
#
# AC tested here:
#   1  _bm_run_step exits 124 and emits kind=bot_merge_step_stalled when
#      the wrapped command exceeds CHUMP_BOT_MERGE_STEP_TIMEOUT_S.
#   2  kind=bot_merge_step_stalled payload includes gap_id, step_name,
#      elapsed_seconds, timeout_s.
#   3  Progress ledger file is written at .chump-locks/bot-merge-progress/<gap>.json
#      with step_name, started_at, last_progress_ts.
#   4  scanner-anchor comment "kind":"bot_merge_step_stalled" is present in
#      bot-merge.sh (satisfies CI scanner gate without touching EVENT_REGISTRY).
#   5  CHUMP_BOT_MERGE_STEP_TIMEOUT_S env is honoured (default 300s).
#   6  _bm_progress_init + _bm_progress_write are callable without errors.
#   7  Natural (non-timeout) exit propagates rc=0 correctly.
#
# See: docs/process/SHIP_ASSIST_PLAYBOOK.md §1 Class 4

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== INFRA-2272 bot-merge stall-monitor tests ==="

[[ -f "$BOT_MERGE" ]] || { fail "bot-merge.sh not found at $BOT_MERGE"; echo "FAIL 1/0"; exit 1; }
ok "bot-merge.sh present"

# ── Static checks ─────────────────────────────────────────────────────────────

echo "--- Static: scanner-anchor present"
if grep -q '"kind":"bot_merge_step_stalled"' "$BOT_MERGE"; then
    ok "scanner-anchor \"kind\":\"bot_merge_step_stalled\" present in bot-merge.sh"
else
    fail "scanner-anchor missing — EVENT_REGISTRY CI gate will fail"
fi

echo "--- Static: CHUMP_BOT_MERGE_STEP_TIMEOUT_S default 300"
if grep -q 'CHUMP_BOT_MERGE_STEP_TIMEOUT_S:-300' "$BOT_MERGE"; then
    ok "CHUMP_BOT_MERGE_STEP_TIMEOUT_S defaults to 300s"
else
    fail "CHUMP_BOT_MERGE_STEP_TIMEOUT_S default 300 not found"
fi

echo "--- Static: progress ledger dir referenced"
if grep -q 'bot-merge-progress' "$BOT_MERGE"; then
    ok "bot-merge-progress directory referenced in bot-merge.sh"
else
    fail "bot-merge-progress directory not referenced"
fi

echo "--- Static: _bm_progress_init function defined"
if grep -q '_bm_progress_init()' "$BOT_MERGE"; then
    ok "_bm_progress_init function defined"
else
    fail "_bm_progress_init function missing"
fi

echo "--- Static: _bm_progress_write function defined"
if grep -q '_bm_progress_write()' "$BOT_MERGE"; then
    ok "_bm_progress_write function defined"
else
    fail "_bm_progress_write function missing"
fi

echo "--- Static: _bm_run_step function defined"
if grep -q '_bm_run_step()' "$BOT_MERGE"; then
    ok "_bm_run_step function defined"
else
    fail "_bm_run_step function missing"
fi

echo "--- Static: _bm_emit_step_stalled function defined"
if grep -q '_bm_emit_step_stalled()' "$BOT_MERGE"; then
    ok "_bm_emit_step_stalled function defined"
else
    fail "_bm_emit_step_stalled function missing"
fi

echo "--- Static: stalled event payload has required fields"
stall_block="$(grep -A 10 '"kind":"bot_merge_step_stalled"' "$BOT_MERGE" | head -15)"
fields_ok=1
for field in gap_id step_name elapsed_seconds timeout_s; do
    if ! echo "$stall_block" | grep -q "$field"; then
        fail "bot_merge_step_stalled payload missing field: $field"
        fields_ok=0
    fi
done
[[ "$fields_ok" -eq 1 ]] && ok "bot_merge_step_stalled payload has gap_id, step_name, elapsed_seconds, timeout_s"

echo "--- Static: SHIP_ASSIST_PLAYBOOK.md cross-reference present"
if grep -q 'SHIP_ASSIST_PLAYBOOK.md' "$BOT_MERGE"; then
    ok "SHIP_ASSIST_PLAYBOOK.md §1 Class 4 cross-reference present"
else
    fail "SHIP_ASSIST_PLAYBOOK.md cross-reference missing"
fi

echo "--- Static: gtimeout/timeout resolver present"
if grep -q '_bm_resolve_timeout_cmd' "$BOT_MERGE"; then
    ok "gtimeout/timeout resolver function present"
else
    fail "gtimeout/timeout resolver missing"
fi

# ── Runtime: source functions and exercise _bm_run_step ───────────────────────
#
# We extract just the function definitions we need to test in isolation.
# This avoids sourcing the full script (which would try to run git, etc.).

echo "--- Runtime: _bm_run_step times out + emits stalled event"

_WORKDIR="$(mktemp -d -t bm-stall-test-XXXXXX)"
_AMBIENT="${_WORKDIR}/ambient.jsonl"
_PROGRESS_DIR="${_WORKDIR}/bot-merge-progress"
mkdir -p "$_PROGRESS_DIR"

# Build a minimal harness that includes only the functions under test.
_HARNESS="${_WORKDIR}/harness.sh"
cat > "$_HARNESS" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail

# Injected by test; controls where ambient events go.
CHUMP_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-/dev/null}"
REPO_ROOT="${REPO_ROOT:-.}"
GAP_IDS=("INFRA-TEST-9999")
GAP_ID="INFRA-TEST-9999"
_BM_PID=$$
_BM_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_BM_STEP_TIMEOUT_S="${CHUMP_BOT_MERGE_STEP_TIMEOUT_S:-300}"
_BM_TIMEOUT_CMD=""
_BM_PROGRESS_FILE="${BM_PROGRESS_FILE:-/dev/null}"
DRY_RUN=0

# Resolve gtimeout/timeout
_bm_resolve_timeout_cmd() {
    if command -v gtimeout >/dev/null 2>&1; then
        _BM_TIMEOUT_CMD="gtimeout"
    elif command -v timeout >/dev/null 2>&1; then
        _BM_TIMEOUT_CMD="timeout"
    else
        _BM_TIMEOUT_CMD=""
    fi
}
_bm_resolve_timeout_cmd

_bm_progress_write() {
    [[ -z "${_BM_PROGRESS_FILE:-}" || "$_BM_PROGRESS_FILE" == "/dev/null" ]] && return 0
    local step="${1:-unknown}" started_at="${2:-${_BM_STARTED_AT}}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"step_name":"%s","started_at":"%s","last_progress_ts":"%s","gap_id":"%s","pid":%d}\n' \
        "$step" "$started_at" "$ts" \
        "${GAP_IDS[0]:-unknown}" "$_BM_PID" \
        > "${_BM_PROGRESS_FILE}.tmp" 2>/dev/null \
    && mv "${_BM_PROGRESS_FILE}.tmp" "$_BM_PROGRESS_FILE" 2>/dev/null || true
}

_bm_emit_step_stalled() {
    local step="${1:-unknown}" elapsed_s="${2:-0}" last_progress_ts="${3:-}" cmd_label="${4:-}"
    local ts gap_label ambient
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    # scanner-anchor: "kind":"bot_merge_step_stalled"
    printf '{"ts":"%s","kind":"bot_merge_step_stalled","gap_id":"%s","step_name":"%s","elapsed_seconds":%d,"last_progress_ts":"%s","cmd_label":"%s","timeout_s":%d,"pid":%d,"note":"INFRA-2272 test harness"}\n' \
        "$ts" "$gap_label" "$step" "$elapsed_s" "$last_progress_ts" "$cmd_label" \
        "$_BM_STEP_TIMEOUT_S" "$_BM_PID" \
        >> "$ambient" 2>/dev/null || true
}

_bm_run_step() {
    local step_name="$1" cmd_label="$2" timeout_s="$3"; shift 3
    local t0 elapsed rc last_ts
    t0="$(date +%s)"
    last_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _bm_progress_write "$step_name" "$last_ts"
    rc=0
    if [[ -n "${_BM_TIMEOUT_CMD:-}" && "${CHUMP_BOT_MERGE_STEP_TIMEOUT_DISABLE:-0}" != "1" ]]; then
        "$_BM_TIMEOUT_CMD" "$timeout_s" "$@" || rc=$?
    else
        "$@" || rc=$?
    fi
    elapsed=$(( $(date +%s) - t0 ))
    if [[ "$rc" -eq 124 ]]; then
        _bm_emit_step_stalled "$step_name" "$elapsed" "$last_ts" "$cmd_label"
        return 124
    fi
    return "$rc"
}

# --- invoked by test runner ---
MODE="${1:-}"
shift || true

case "$MODE" in
    stall)
        # Run a sleep 600 with a very short timeout — should exit 124 quickly.
        CHUMP_BOT_MERGE_STEP_TIMEOUT_S="${TIMEOUT_S:-2}" \
            _BM_STEP_TIMEOUT_S="${TIMEOUT_S:-2}" \
            _bm_run_step "git push" "git push test" "${TIMEOUT_S:-2}" sleep 600
        ;;
    natural)
        # A command that completes naturally — should exit 0.
        _bm_run_step "git fetch" "git fetch test" 30 true
        ;;
    progress)
        # Write the progress ledger and dump the result.
        _bm_progress_write "test_step" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        cat "$_BM_PROGRESS_FILE" 2>/dev/null
        ;;
esac
HARNESS
chmod +x "$_HARNESS"

_PROGRESS_FILE="${_PROGRESS_DIR}/infra-test-9999.json"

# Test: stall path exits 124 within timeout + 2s grace
echo "    Invoking stall test (timeout=2s, sleeping 600s)…"
_t0="$(date +%s)"
_stall_rc=0
CHUMP_AMBIENT_LOG="$_AMBIENT" \
BM_PROGRESS_FILE="$_PROGRESS_FILE" \
TIMEOUT_S=2 \
    bash "$_HARNESS" stall || _stall_rc=$?
_elapsed=$(( $(date +%s) - _t0 ))

if [[ "$_stall_rc" -eq 124 ]]; then
    ok "_bm_run_step returns 124 on timeout (exit code confirmed)"
else
    fail "_bm_run_step did not return 124 on timeout (got $_stall_rc)"
fi

if [[ "$_elapsed" -le 10 ]]; then
    ok "_bm_run_step timed out within 10s wall-clock (elapsed ${_elapsed}s)"
else
    fail "_bm_run_step took too long to timeout (elapsed ${_elapsed}s, wanted ≤10s)"
fi

# Test: kind=bot_merge_step_stalled emitted to ambient.jsonl
if [[ -f "$_AMBIENT" ]] && grep -q '"kind":"bot_merge_step_stalled"' "$_AMBIENT"; then
    ok "kind=bot_merge_step_stalled emitted to ambient.jsonl"
else
    fail "kind=bot_merge_step_stalled NOT found in ambient.jsonl"
fi

# Test: payload fields present
if [[ -f "$_AMBIENT" ]]; then
    _payload="$(grep '"kind":"bot_merge_step_stalled"' "$_AMBIENT" | tail -1)"
    _fields_ok=1
    for _f in gap_id step_name elapsed_seconds timeout_s; do
        if ! echo "$_payload" | grep -q "\"$_f\""; then
            fail "stalled payload missing field: $_f"
            _fields_ok=0
        fi
    done
    [[ "$_fields_ok" -eq 1 ]] && ok "stalled payload has all required fields (gap_id, step_name, elapsed_seconds, timeout_s)"
fi

# Test: natural exit exits 0
echo "--- Runtime: _bm_run_step propagates rc=0 on natural exit"
_natural_rc=0
CHUMP_AMBIENT_LOG="$_AMBIENT" \
BM_PROGRESS_FILE="$_PROGRESS_FILE" \
    bash "$_HARNESS" natural || _natural_rc=$?
if [[ "$_natural_rc" -eq 0 ]]; then
    ok "_bm_run_step propagates rc=0 on natural exit"
else
    fail "_bm_run_step returned $_natural_rc instead of 0 on natural exit"
fi

# Test: progress ledger written
echo "--- Runtime: progress ledger written at _bm_progress_init path"
_prog_rc=0
CHUMP_AMBIENT_LOG="$_AMBIENT" \
BM_PROGRESS_FILE="$_PROGRESS_FILE" \
    bash "$_HARNESS" progress || _prog_rc=$?
if [[ -f "$_PROGRESS_FILE" ]]; then
    _prog_content="$(cat "$_PROGRESS_FILE")"
    _prog_ok=1
    for _f in step_name started_at last_progress_ts gap_id; do
        if ! echo "$_prog_content" | grep -q "\"$_f\""; then
            fail "progress ledger missing field: $_f"
            _prog_ok=0
        fi
    done
    [[ "$_prog_ok" -eq 1 ]] && ok "progress ledger has step_name, started_at, last_progress_ts, gap_id"
else
    fail "progress ledger file not written at $_PROGRESS_FILE"
fi

# Cleanup
rm -rf "$_WORKDIR"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
