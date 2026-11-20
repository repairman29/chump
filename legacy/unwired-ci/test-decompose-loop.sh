#!/usr/bin/env bash
# test-decompose-loop.sh — INFRA-1924 smoke test
#
# Validates scripts/coord/decompose-loop.sh:
#   - help / heartbeat / audit-pending exit 0 on happy path
#   - bad subcommand exits 2; missing-arg exits 1
#   - heartbeat emits kind=decompose_heartbeat to ambient
#   - audit-pending emits kind=decompose_audit to ambient
#   - slice --dry-run with a synthetic gap_id propagates exit code correctly

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SCRIPT="scripts/coord/decompose-loop.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not executable"
    exit 1
fi

# Use an isolated ambient log so we don't pollute the real one
TMP_AMBIENT="$(mktemp -d)/ambient.jsonl"
touch "$TMP_AMBIENT"

# ── Test 1: help exits 0 + prints usage ────────────────────────────────────
help_out="$(bash "$SCRIPT" help 2>&1 || true)"
if ! echo "$help_out" | grep -q "Subcommands:"; then
    echo "FAIL: help did not print 'Subcommands:'"
    exit 1
fi
echo "  ok: help prints Subcommands"

# ── Test 2: bad subcommand exits 2 ─────────────────────────────────────────
set +e
bash "$SCRIPT" totally-not-a-command >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" != "2" ]]; then
    echo "FAIL: bad subcommand should exit 2, got $rc"
    exit 1
fi
echo "  ok: bad subcommand exits 2"

# ── Test 3: slice with no arg exits 1 ─────────────────────────────────────
set +e
CHUMP_AMBIENT_LOG="$TMP_AMBIENT" bash "$SCRIPT" slice >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" != "1" ]]; then
    echo "FAIL: slice with no arg should exit 1, got $rc"
    exit 1
fi
echo "  ok: slice with no arg exits 1"

# ── Test 4: heartbeat exits 0 + emits kind=decompose_heartbeat ─────────────
: > "$TMP_AMBIENT"
CHUMP_AMBIENT_LOG="$TMP_AMBIENT" CHUMP_DECOMPOSE_NO_BROADCAST=1 \
    CHUMP_SESSION_ID="test-decompose" \
    bash "$SCRIPT" heartbeat >/dev/null 2>&1
if ! grep -q '"kind":"decompose_heartbeat"' "$TMP_AMBIENT"; then
    echo "FAIL: heartbeat did not emit kind=decompose_heartbeat"
    cat "$TMP_AMBIENT"
    exit 1
fi
echo "  ok: heartbeat emits kind=decompose_heartbeat"

# ── Test 5: audit-pending exits 0 + emits kind=decompose_audit ─────────────
# Only run if chump CLI available; otherwise skip (CI envs without it).
if command -v chump >/dev/null 2>&1; then
    : > "$TMP_AMBIENT"
    set +e
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" CHUMP_SESSION_ID="test-decompose" \
        bash "$SCRIPT" audit-pending >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" != "0" ]]; then
        echo "FAIL: audit-pending should exit 0 (stop condition), got $rc"
        exit 1
    fi
    if ! grep -q '"kind":"decompose_audit"' "$TMP_AMBIENT"; then
        echo "FAIL: audit-pending did not emit kind=decompose_audit"
        cat "$TMP_AMBIENT"
        exit 1
    fi
    echo "  ok: audit-pending exits 0 + emits kind=decompose_audit"
else
    echo "  skip: audit-pending — chump CLI not on PATH"
fi

# ── Test 6: slice with non-existent gap exits 1 ───────────────────────────
if command -v chump >/dev/null 2>&1; then
    set +e
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
        bash "$SCRIPT" slice INFRA-9999999 --dry-run >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" != "1" ]]; then
        echo "FAIL: slice with non-existent gap should exit 1, got $rc"
        exit 1
    fi
    echo "  ok: slice with non-existent gap exits 1"
else
    echo "  skip: slice non-existent gap — chump CLI not on PATH"
fi

# ── Test 7: --help on subcommand exits 0 ──────────────────────────────────
set +e
bash "$SCRIPT" slice --help >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" != "0" ]]; then
    echo "FAIL: 'slice --help' should exit 0, got $rc"
    exit 1
fi
echo "  ok: slice --help exits 0"

# ── Test 8 (META-160): tick with stubbed inbox + FEEDBACK emits actionable ──
# This test exercises Phase 0: _drain_inbox + _peek_pending_feedback.
# The test does NOT require chump CLI — it only uses the Phase 0 helpers.
{
    TMP_DIR8="$(mktemp -d)"
    TMP_AMB8="$TMP_DIR8/ambient.jsonl"
    TMP_LOCK8="$TMP_DIR8/locks"
    SESSION8="test-decompose-p0"
    mkdir -p "$TMP_LOCK8/inbox"

    # Stub inbox: 1 message in SESSION8's inbox file
    printf '{"ts":"2026-05-30T00:00:00Z","kind":"decompose_request","gap_id":"META-TEST-1","rationale":"test"}\n' \
        > "$TMP_LOCK8/inbox/${SESSION8}.jsonl"

    # Stub ambient: 1 FEEDBACK/proposal event with corr_id "TEST-CORR-1"
    # (no consensus_result → should surface as pending)
    printf '{"ts":"2026-05-30T00:00:01Z","event":"FEEDBACK","kind":"proposal","corr_id":"TEST-CORR-1","body":"needs vote"}\n' \
        > "$TMP_AMB8"

    set +e
    tick_out="$(
        CHUMP_FLEET_RECV_SIDE_V0=1 \
        CHUMP_AMBIENT_LOG="$TMP_AMB8" \
        CHUMP_LOCK_DIR="$TMP_LOCK8" \
        CHUMP_SESSION_ID="$SESSION8" \
        bash "$SCRIPT" tick 2>&1 || true
    )"
    set -e

    # Assert "Pending FEEDBACK" header present in stdout
    if ! printf '%s\n' "$tick_out" | grep -q "Pending FEEDBACK"; then
        echo "FAIL Test 8: 'Pending FEEDBACK' header not found in tick output"
        printf '%s\n' "$tick_out"
        exit 1
    fi
    echo "  ok Test 8: tick with FEEDBACK proposal prints 'Pending FEEDBACK' header"

    # Assert corr_id surfaced
    if ! printf '%s\n' "$tick_out" | grep -q "TEST-CORR-1"; then
        echo "FAIL Test 8: corr_id 'TEST-CORR-1' not found in tick output"
        printf '%s\n' "$tick_out"
        exit 1
    fi
    echo "  ok Test 8: tick surfaces corr_id TEST-CORR-1"

    # Assert inbox message was printed (drain)
    if ! printf '%s\n' "$tick_out" | grep -q "decompose_request"; then
        echo "FAIL Test 8: inbox message not printed in tick output"
        printf '%s\n' "$tick_out"
        exit 1
    fi
    echo "  ok Test 8: inbox drained and message printed"

    # Assert cursor advanced
    cursor_file="$TMP_LOCK8/inbox/${SESSION8}.cursor"
    if [[ ! -f "$cursor_file" ]]; then
        echo "FAIL Test 8: cursor file not created at $cursor_file"
        exit 1
    fi
    cursor_val="$(cat "$cursor_file")"
    if [[ "$cursor_val" != "1" ]]; then
        echo "FAIL Test 8: cursor should be 1, got '$cursor_val'"
        exit 1
    fi
    echo "  ok Test 8: inbox cursor advanced to 1"

    # Verify feature-flag gate: without CHUMP_FLEET_RECV_SIDE_V0, Phase 0 skipped
    set +e
    tick_out_gated="$(
        CHUMP_FLEET_RECV_SIDE_V0=0 \
        CHUMP_AMBIENT_LOG="$TMP_AMB8" \
        CHUMP_LOCK_DIR="$TMP_LOCK8" \
        CHUMP_SESSION_ID="${SESSION8}-gated" \
        bash "$SCRIPT" tick 2>&1 || true
    )"
    set -e
    if printf '%s\n' "$tick_out_gated" | grep -q "Pending FEEDBACK"; then
        echo "FAIL Test 8: Phase 0 ran even though CHUMP_FLEET_RECV_SIDE_V0=0"
        exit 1
    fi
    echo "  ok Test 8: feature flag gates Phase 0 correctly"

    rm -rf "$TMP_DIR8"
}

echo "test-decompose-loop: PASS"
