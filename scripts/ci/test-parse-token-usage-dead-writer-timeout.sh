#!/usr/bin/env bash
# RESILIENT-361: regression test — _parse_token_usage.py must not wedge
# forever on a dead-writer FIFO.
#
# Observed 2026-08-21: two CJ workers frozen ~5h because the parser's
# `open(fifo)` / `for raw in fh` blocks forever when no writer ever connects
# (or the writer dies without closing its end). This test proves the
# CHUMP_TOKEN_PARSE_TIMEOUT_S SIGALRM bound actually unblocks the read —
# it opens a fifo, holds the write-end open on a background subshell that
# never writes or closes, and asserts the parser process exits well inside
# the configured timeout instead of hanging indefinitely.
#
# Without the RESILIENT-361 SIGALRM fix, this test times out (fails) because
# the parser blocks forever on open(fifo_path).
#
# Run from repo root: bash scripts/ci/test-parse-token-usage-dead-writer-timeout.sh
set -uo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

cleanup() {
    [[ -n "${_holder_pid:-}" ]] && kill "$_holder_pid" 2>/dev/null
    [[ -n "${_parser_pid:-}" ]] && kill -9 "$_parser_pid" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

mkdir -p "$SANDBOX/.chump-locks"
AMBIENT="$SANDBOX/.chump-locks/ambient.jsonl"

_fifo="$SANDBOX/dead-writer.fifo"
mkfifo "$_fifo"

# Hold the write-end open (satisfies open(fifo) on the reader side) but never
# write any data and never close it — this is the dead-writer wedge shape.
( exec 3>"$_fifo"; sleep 300 ) &
_holder_pid=$!

CHUMP_TOKEN_PARSE_TIMEOUT_S=1 python3 "$REPO_ROOT/scripts/dispatch/_parse_token_usage.py" \
    "$_fifo" "$AMBIENT" "RESILIENT-361" "1-RESILIENT-361-test" "sess-deadwriter-1" &
_parser_pid=$!

# Bound the wait itself so a regression (parser never exits) fails fast
# instead of hanging the CI job — well above the 1s alarm, well below a
# real fleet wedge.
_deadline=$((SECONDS + 15))
_exited=0
while (( SECONDS < _deadline )); do
    if ! kill -0 "$_parser_pid" 2>/dev/null; then
        _exited=1
        break
    fi
    sleep 0.2
done

if [[ "$_exited" -eq 1 ]]; then
    pass "parser exited on its own after dead-writer timeout (bound=1s)"
else
    fail "parser still running >15s after dead-writer fifo — SIGALRM bound did not fire"
fi

kill "$_holder_pid" 2>/dev/null
wait "$_holder_pid" 2>/dev/null
kill -9 "$_parser_pid" 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
