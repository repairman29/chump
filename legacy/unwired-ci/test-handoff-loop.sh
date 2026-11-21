#!/usr/bin/env bash
# test-handoff-loop.sh — INFRA-1922: smoke test for scripts/coord/handoff-loop.sh.
#
# Exercises each subcommand on a synthetic happy path and asserts the
# documented exit codes (0 = success, 1 = quiet, 2 = bad input, 3 = missing
# state). Plus asserts the ambient emissions land in CHUMP_AMBIENT_LOG with
# the right kind tags (handoff_heartbeat, sub_agent_dispatched).

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/handoff-loop.sh"

if [[ ! -x "$LOOP_SCRIPT" ]]; then
    echo "FAIL: $LOOP_SCRIPT not found or not executable" >&2
    exit 1
fi

_pass=0
_fail=0

_ok()   { echo "  ✓ $*"; _pass=$((_pass + 1)); }
_bad()  { echo "  ✗ FAIL: $*" >&2; _fail=$((_fail + 1)); }

# ── Test 1: help exits 0 ───────────────────────────────────────────────────
echo "Test 1: help subcommand..."
if "$LOOP_SCRIPT" help >/dev/null 2>&1; then
    _ok "help exits 0"
else
    _bad "help should exit 0"
fi

# ── Test 2: heartbeat emits handoff_heartbeat ──────────────────────────────
echo "Test 2: heartbeat subcommand..."
_dir2="$(mktemp -d)"
_amb2="$_dir2/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb2" \
CHUMP_SESSION_ID="test-handoff-heartbeat" \
"$LOOP_SCRIPT" heartbeat >/dev/null 2>&1 || _rc=$?

if (( _rc == 0 )); then
    _ok "heartbeat exits 0"
else
    _bad "heartbeat should exit 0, got $_rc"
fi

if grep -q '"kind":"handoff_heartbeat"' "$_amb2" 2>/dev/null; then
    _ok "heartbeat emits handoff_heartbeat kind"
else
    _bad "heartbeat did not emit handoff_heartbeat to ambient"
fi

if grep -q '"session":"test-handoff-heartbeat"' "$_amb2" 2>/dev/null; then
    _ok "heartbeat preserves CHUMP_SESSION_ID in emit"
else
    _bad "heartbeat did not pick up CHUMP_SESSION_ID"
fi
rm -rf "$_dir2"

# ── Test 3: dispatch-sub emits sub_agent_dispatched ───────────────────────
echo "Test 3: dispatch-sub subcommand..."
_dir3="$(mktemp -d)"
_amb3="$_dir3/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb3" \
CHUMP_SESSION_ID="test-handoff-dispatch" \
"$LOOP_SCRIPT" dispatch-sub INFRA-9999 >/dev/null 2>&1 || _rc=$?

if (( _rc == 0 )); then
    _ok "dispatch-sub exits 0 on valid gap-id"
else
    _bad "dispatch-sub should exit 0, got $_rc"
fi

if grep -q '"kind":"sub_agent_dispatched"' "$_amb3" 2>/dev/null; then
    _ok "dispatch-sub emits sub_agent_dispatched kind"
else
    _bad "dispatch-sub did not emit sub_agent_dispatched"
fi

if grep -q '"gap":"INFRA-9999"' "$_amb3" 2>/dev/null; then
    _ok "dispatch-sub records target gap in emit"
else
    _bad "dispatch-sub did not record target gap"
fi

# Output should include the dispatch prompt + the SUBAGENT_DISPATCH reference
_dispatch_out="$(CHUMP_AMBIENT_LOG="$_amb3" CHUMP_SESSION_ID="test-handoff-dispatch" \
    "$LOOP_SCRIPT" dispatch-sub INFRA-9999 2>&1 || true)"
if echo "$_dispatch_out" | grep -q "Sonnet sub-agent dispatch prompt"; then
    _ok "dispatch-sub prints dispatch prompt header"
else
    _bad "dispatch-sub missing prompt header"
fi
if echo "$_dispatch_out" | grep -q "SUBAGENT_DISPATCH"; then
    _ok "dispatch-sub references SUBAGENT_DISPATCH.md"
else
    _bad "dispatch-sub did not reference SUBAGENT_DISPATCH.md"
fi
rm -rf "$_dir3"

# ── Test 4: dispatch-sub bad input exits 2 ─────────────────────────────────
echo "Test 4: dispatch-sub bad input..."
_rc=0
"$LOOP_SCRIPT" dispatch-sub >/dev/null 2>&1 || _rc=$?
if (( _rc == 2 )); then
    _ok "dispatch-sub exits 2 when gap-id missing"
else
    _bad "dispatch-sub should exit 2 on missing arg, got $_rc"
fi

# ── Test 5: review-pr happy path ───────────────────────────────────────────
echo "Test 5: review-pr subcommand..."
_rc=0
_out="$("$LOOP_SCRIPT" review-pr 12345 2>&1 || true)"
"$LOOP_SCRIPT" review-pr 12345 >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "review-pr exits 0 with valid PR number"
else
    _bad "review-pr should exit 0, got $_rc"
fi
if echo "$_out" | grep -qE "(Contract|recommendation)"; then
    _ok "review-pr prints contract recommendation"
else
    _bad "review-pr output missing contract recommendation"
fi

# ── Test 6: review-pr bad input exits 2 ────────────────────────────────────
echo "Test 6: review-pr bad input..."
_rc=0
"$LOOP_SCRIPT" review-pr >/dev/null 2>&1 || _rc=$?
if (( _rc == 2 )); then
    _ok "review-pr exits 2 when PR missing"
else
    _bad "review-pr should exit 2 on missing arg, got $_rc"
fi

# ── Test 7: scan-handoffs (any exit code 0 or 1 acceptable) ────────────────
echo "Test 7: scan-handoffs subcommand..."
_rc=0
"$LOOP_SCRIPT" scan-handoffs >/dev/null 2>&1 || _rc=$?
# Either 0 (actionable) or 1 (quiet) is acceptable behavior.
if (( _rc == 0 || _rc == 1 )); then
    _ok "scan-handoffs exits 0 (actionable) or 1 (quiet); got $_rc"
else
    _bad "scan-handoffs should exit 0 or 1, got $_rc"
fi

# ── Test 8: bad subcommand exits 2 ─────────────────────────────────────────
echo "Test 8: unknown subcommand..."
_rc=0
"$LOOP_SCRIPT" not-a-real-subcommand >/dev/null 2>&1 || _rc=$?
if (( _rc == 2 )); then
    _ok "unknown subcommand exits 2"
else
    _bad "unknown subcommand should exit 2, got $_rc"
fi

# ── Test 9: scanner-anchor comments are present in source ──────────────────
echo "Test 9: scanner-anchor discipline (AC #5)..."
if grep -q '# scanner-anchor: "kind":"sub_agent_dispatched"' "$LOOP_SCRIPT"; then
    _ok "sub_agent_dispatched has scanner-anchor comment"
else
    _bad "sub_agent_dispatched missing scanner-anchor comment"
fi
if grep -q '# scanner-anchor: "kind":"handoff_heartbeat"' "$LOOP_SCRIPT"; then
    _ok "handoff_heartbeat has scanner-anchor comment"
else
    _bad "handoff_heartbeat missing scanner-anchor comment"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${_pass} passed, ${_fail} failed"
if (( _fail > 0 )); then
    exit 1
fi
echo "✓ All handoff-loop tests passed"
