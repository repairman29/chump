#!/usr/bin/env bash
# INFRA-639: regression test — partial token attribution on wedge/timeout.
#
# Verifies that:
#   1. _parse_token_usage.py emits token_usage_partial events for each JSON
#      line that carries a .usage field.
#   2. src/waste_tally.rs aggregates orphaned partials (no session_end) under
#      the synthetic kind "session_token_orphan".
#   3. Partials are suppressed when a matching session_end exists.
#
# Run from repo root: bash scripts/ci/test-token-attribution-on-wedge.sh
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

mkdir -p "$SANDBOX/.chump-locks"
AMBIENT="$SANDBOX/.chump-locks/ambient.jsonl"

# ── Test 1: _parse_token_usage.py emits token_usage_partial via fifo ────────

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

_fifo="$(mktemp -u -t chump-test-tok.XXXXXX)"
mkfifo "$_fifo"

python3 "$REPO_ROOT/scripts/dispatch/_parse_token_usage.py" \
    "$_fifo" "$AMBIENT" "INFRA-639" "1-INFRA-639-test" "sess-test-1" &
_parser_pid=$!

# Simulate claude streaming output: one message_delta with usage, one without.
printf '{"type":"message_delta","delta":{"type":"text_delta","text":"hello"},"usage":{"input_tokens":500,"output_tokens":120,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}\n' > "$_fifo"
wait "$_parser_pid" 2>/dev/null || true
rm -f "$_fifo"

if grep -q '"kind":"token_usage_partial"' "$AMBIENT" 2>/dev/null; then
    pass "token_usage_partial event written to ambient.jsonl"
else
    fail "token_usage_partial event NOT found in ambient.jsonl"
fi

if grep -q '"input":500' "$AMBIENT" 2>/dev/null; then
    pass "input token count (500) captured correctly"
else
    fail "input token count missing in token_usage_partial event"
fi

if grep -q '"cache_read":200' "$AMBIENT" 2>/dev/null; then
    pass "cache_read token count (200) captured correctly"
else
    fail "cache_read token count missing in token_usage_partial event"
fi

if grep -q '"gap_id":"INFRA-639"' "$AMBIENT" 2>/dev/null; then
    pass "gap_id attributed in token_usage_partial event"
else
    fail "gap_id missing from token_usage_partial event"
fi

# ── Test 2: _parse_token_usage.py skips lines without usage field ────────────

_fifo2="$(mktemp -u -t chump-test-tok2.XXXXXX)"
mkfifo "$_fifo2"
AMBIENT2="$SANDBOX/.chump-locks/ambient2.jsonl"

python3 "$REPO_ROOT/scripts/dispatch/_parse_token_usage.py" \
    "$_fifo2" "$AMBIENT2" "INFRA-639" "1-INFRA-639-test2" "sess-test-2" &
_parser2_pid=$!
printf '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n' > "$_fifo2"
wait "$_parser2_pid" 2>/dev/null || true
rm -f "$_fifo2"

if [[ ! -f "$AMBIENT2" ]] || ! grep -q '"kind":"token_usage_partial"' "$AMBIENT2" 2>/dev/null; then
    pass "no token_usage_partial emitted for lines without .usage"
else
    fail "spurious token_usage_partial emitted for line without .usage"
fi

# ── Test 3: simulate wedge — partial token in ambient, no session_end ────────
# Build a minimal ambient.jsonl with a token_usage_partial and no session_end,
# then run the waste_tally Rust unit tests (cargo test) which cover this path.

WEDGE_AMBIENT="$SANDBOX/.chump-locks/wedge.jsonl"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"token_usage_partial","session_id":"wedge-sess-1","gap_id":"INFRA-639","cycle_id":"1-INFRA-639-wedge","input":1500,"output":400,"cache_read":600,"cache_creation":0}\n' \
    "$NOW_ISO" > "$WEDGE_AMBIENT"

# Test 3a: verify cargo test for INFRA-639 coverage.
if command -v cargo >/dev/null 2>&1; then
    if cargo test waste_tally::tests::infra639 --quiet 2>/dev/null; then
        pass "Rust waste_tally INFRA-639 unit tests pass"
    else
        fail "Rust waste_tally INFRA-639 unit tests FAILED"
    fi
else
    echo "SKIP: cargo not available — skipping Rust unit test"
fi

# Test 3b: verify that the parser correctly emits session_id + gap_id.
_fifo3="$(mktemp -u -t chump-test-tok3.XXXXXX)"
mkfifo "$_fifo3"
AMBIENT3="$SANDBOX/.chump-locks/ambient3.jsonl"

python3 "$REPO_ROOT/scripts/dispatch/_parse_token_usage.py" \
    "$_fifo3" "$AMBIENT3" "INFRA-timeout" "agent2-INFRA-timeout-20260506" "sess-timeout-1" &
_parser3_pid=$!

# Simulate mid-cycle usage events; then simulate worker kill (close the pipe without more data).
{
    printf '{"type":"message_delta","usage":{"input_tokens":1000,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    printf '{"type":"message_delta","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    # Worker killed here — no further output, pipe closes.
} > "$_fifo3"
wait "$_parser3_pid" 2>/dev/null || true
rm -f "$_fifo3"

_partial_count="$(grep -c '"kind":"token_usage_partial"' "$AMBIENT3" 2>/dev/null || echo 0)"
if [[ "$_partial_count" -ge 1 ]]; then
    pass "partial events captured during simulated mid-cycle timeout (count=$_partial_count)"
else
    fail "no partial events captured for simulated wedge"
fi

if grep -q '"gap_id":"INFRA-timeout"' "$AMBIENT3" 2>/dev/null; then
    pass "gap_id attributed on mid-cycle partial events"
else
    fail "gap_id missing from mid-cycle partial events"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
