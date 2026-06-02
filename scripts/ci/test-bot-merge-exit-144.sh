#!/usr/bin/env bash
# test-bot-merge-exit-144.sh — RESILIENT-052 regression test
#
# Verifies that bot-merge.sh exits 144 LOUD (non-empty stdout) when
# ambient.jsonl contains a recent graphql_exhausted event.
#
# Root cause being tested:
#   The graphql_exhausted wedge guard (INFRA-1939) fires BEFORE the tee
#   stdout redirect (line ~1387 in bot-merge.sh). Prior to RESILIENT-052,
#   all WEDGE diagnostic lines went to >&2 only, so agents capturing stdout
#   saw an empty log and exit 144 — a "silent stall" that looked identical
#   to an OOM or unhandled signal kill.
#
# Fix: wedge guard now prints to stdout (via plain printf, not >&2) before
# exiting 144, so stdout is always non-empty on this exit path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

FAKE_AMBIENT="$TMPDIR_TEST/ambient.jsonl"
FAKE_LOCKS_DIR="$TMPDIR_TEST/.chump-locks"
mkdir -p "$FAKE_LOCKS_DIR"

# Inject a recent graphql_exhausted event (timestamp = now so it's inside the
# 1800s lookback window).
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"graphql_exhausted","source":"test-inject","note":"RESILIENT-052 test fixture"}\n' \
    "$NOW_TS" > "$FAKE_AMBIENT"

# ── Test 1: exit code is 144 ─────────────────────────────────────────────────
stdout_out="$TMPDIR_TEST/stdout.txt"
stderr_out="$TMPDIR_TEST/stderr.txt"

rc=0
CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=0 \
CHUMP_GH_PROBE_SKIP=1 \
CHUMP_BOT_MERGE_NO_TEE=1 \
CHUMP_PREFLIGHT_SKIP=1 \
    bash "$BOT_MERGE" --gap none --dry-run \
    >"$stdout_out" 2>"$stderr_out" || rc=$?

if [[ "$rc" -ne 144 ]]; then
    fail "test1: expected exit 144, got exit $rc"
    printf '  stdout:\n'; cat "$stdout_out"
    printf '  stderr:\n'; cat "$stderr_out"
    exit 1
fi
pass "test1: exit code is 144"

# ── Test 2: stdout is non-empty (the silent-stall fix) ───────────────────────
stdout_bytes="$(wc -c < "$stdout_out" | tr -d ' ')"
if [[ "$stdout_bytes" -eq 0 ]]; then
    fail "test2: stdout is EMPTY on exit 144 — silent stall bug REPRODUCED (RESILIENT-052 fix not applied?)"
    printf '  stderr was:\n'; cat "$stderr_out"
    exit 1
fi
pass "test2: stdout is non-empty ($stdout_bytes bytes) on exit 144"

# ── Test 3: stdout contains a recognizable WEDGE diagnostic ─────────────────
if ! grep -q "EXIT-144 WEDGE\|WEDGE.*graphql_exhausted\|WEDGE.*bot-merge" "$stdout_out"; then
    fail "test3: stdout does not contain WEDGE diagnostic keyword"
    printf '  stdout was:\n'; cat "$stdout_out"
    exit 1
fi
pass "test3: stdout contains WEDGE diagnostic keyword"

# ── Test 4: bypass flag suppresses the wedge check (should NOT exit 144) ────
# With CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1, the wedge guard is skipped.
# The script will still fail (no real branch / gh access), but exit != 144.
rc2=0
CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1 \
CHUMP_GH_PROBE_SKIP=1 \
CHUMP_BOT_MERGE_NO_TEE=1 \
CHUMP_PREFLIGHT_SKIP=1 \
    bash "$BOT_MERGE" --gap none --dry-run \
    >"$TMPDIR_TEST/bypass_stdout.txt" 2>"$TMPDIR_TEST/bypass_stderr.txt" || rc2=$?

if [[ "$rc2" -eq 144 ]]; then
    fail "test4: bypass flag CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1 did not prevent exit 144"
    exit 1
fi
pass "test4: bypass flag prevents wedge exit (got exit $rc2 instead of 144)"

# ── Test 5: stale graphql_exhausted event (outside lookback) does NOT trigger ─
STALE_AMBIENT="$TMPDIR_TEST/stale_ambient.jsonl"
# Use a timestamp 2 hours ago — well outside the default 1800s lookback
STALE_TS="$(date -u -v-7200S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(( $(date +%s) - 7200 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "2020-01-01T00:00:00Z")"
printf '{"ts":"%s","kind":"graphql_exhausted","source":"test-inject-stale","note":"stale fixture"}\n' \
    "$STALE_TS" > "$STALE_AMBIENT"

rc3=0
CHUMP_AMBIENT_LOG="$STALE_AMBIENT" \
CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=0 \
CHUMP_GH_PROBE_SKIP=1 \
CHUMP_BOT_MERGE_NO_TEE=1 \
CHUMP_PREFLIGHT_SKIP=1 \
    bash "$BOT_MERGE" --gap none --dry-run \
    >"$TMPDIR_TEST/stale_stdout.txt" 2>"$TMPDIR_TEST/stale_stderr.txt" || rc3=$?

if [[ "$rc3" -eq 144 ]]; then
    fail "test5: stale graphql_exhausted (2h old) should NOT trigger wedge exit 144 (got 144)"
    exit 1
fi
pass "test5: stale graphql_exhausted event (outside lookback) does not trigger wedge (exit $rc3)"

echo ""
pass "ALL TESTS PASSED (RESILIENT-052)"
