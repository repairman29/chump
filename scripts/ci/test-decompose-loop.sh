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

# ── Test 8 (INFRA-1798): tick's Glance phase drains inbox + votes ─────────
# Supersedes the old META-160 read-only Phase 0. The Glance phase (shared
# scripts/coord/lib/inbox-glance-act.sh) now drains via the canonical
# chump-inbox.sh (unconditionally — draining is not feature-flag gated) and
# casts a vote on any open FEEDBACK/proposal not yet voted (gated behind
# CHUMP_FLEET_RECV_SIDE_V0, per META-159). A stub `chump` binary on PATH
# keeps this deterministic without a real CLI/DB dependency.
{
    TMP_DIR8="$(mktemp -d)"
    TMP_LOCK8="$TMP_DIR8/locks"
    TMP_BIN8="$TMP_DIR8/bin"
    SESSION8="test-decompose-p0"
    mkdir -p "$TMP_LOCK8/inbox" "$TMP_BIN8"

    # Stub inbox: 1 message in SESSION8's inbox file
    printf '{"ts":"2026-05-30T00:00:00Z","event":"INTENT","session":"peer-x","kind":"decompose_request","gap_id":"META-TEST-1","rationale":"test"}\n' \
        > "$TMP_LOCK8/inbox/${SESSION8}.jsonl"

    # Ambient MUST live at $LOCK_DIR/ambient.jsonl — chump-inbox.sh and the
    # glance lib both hard-resolve to that path (they don't honour
    # CHUMP_AMBIENT_LOG), so this test writes there directly rather than to
    # a separate override file.
    TMP_AMB8="$TMP_LOCK8/ambient.jsonl"
    printf '{"ts":"2026-05-30T00:00:01Z","event":"FEEDBACK","kind":"proposal","corr_id":"TEST-CORR-1","body":"needs vote"}\n' \
        > "$TMP_AMB8"

    # Stub `chump` CLI: only the `vote` subcommand is exercised here; record
    # the call and emit the same ambient line the real vote.rs would.
    cat > "$TMP_BIN8/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "vote" ]]; then
    corr="$2"; v="$3"; shift 3
    reason=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" == "--reason" ]] && { reason="$2"; shift; }
        shift
    done
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":%s,"rationale":"%s","session":"%s"}\n' \
        "$ts" "$corr" "$v" "$reason" "${CHUMP_SESSION_ID:-unknown}" >> "$CHUMP_STUB_AMBIENT"
    exit 0
fi
exit 0
STUB
    chmod +x "$TMP_BIN8/chump"

    set +e
    tick_out="$(
        CHUMP_FLEET_RECV_SIDE_V0=1 \
        CHUMP_LOCK_DIR="$TMP_LOCK8" \
        CHUMP_SESSION_ID="$SESSION8" \
        CHUMP_STUB_AMBIENT="$TMP_AMB8" \
        PATH="$TMP_BIN8:$PATH" \
        bash "$SCRIPT" tick 2>&1 || true
    )"
    set -e

    # Assert the Glance header ran.
    if ! printf '%s\n' "$tick_out" | grep -q "## Glance: inbox drain + act"; then
        echo "FAIL Test 8: Glance phase header not found in tick output"
        printf '%s\n' "$tick_out"
        exit 1
    fi
    echo "  ok Test 8: Glance phase runs as first step of tick"

    # Assert 1 inbox item was read.
    if ! printf '%s\n' "$tick_out" | grep -q "items_read=1"; then
        echo "FAIL Test 8: expected items_read=1 in tick output"
        printf '%s\n' "$tick_out"
        exit 1
    fi
    echo "  ok Test 8: inbox message drained (items_read=1)"

    # Assert cursor advanced (proves chump-inbox.sh read — not a re-implemented
    # peek — ran). chump-inbox.sh's cursor is a BYTE offset (tail -c +N), not
    # a line count, so assert it matches the inbox file's byte size.
    cursor_file="$TMP_LOCK8/inbox/${SESSION8}.cursor"
    if [[ ! -f "$cursor_file" ]]; then
        echo "FAIL Test 8: cursor file not created at $cursor_file"
        exit 1
    fi
    cursor_val="$(cat "$cursor_file")"
    inbox_bytes="$(wc -c < "$TMP_LOCK8/inbox/${SESSION8}.jsonl" | tr -d ' ')"
    if [[ "$cursor_val" != "$inbox_bytes" ]]; then
        echo "FAIL Test 8: cursor should be $inbox_bytes (byte offset), got '$cursor_val'"
        exit 1
    fi
    echo "  ok Test 8: inbox cursor advanced to end-of-file byte offset"

    # Assert kind=inbox_advance emitted (chump-inbox.sh's own emit, AC3).
    if ! grep -q '"kind":"inbox_advance"' "$TMP_AMB8"; then
        echo "FAIL Test 8: kind=inbox_advance not emitted to ambient"
        cat "$TMP_AMB8"
        exit 1
    fi
    echo "  ok Test 8: kind=inbox_advance emitted"

    # Assert the open proposal got a vote cast (AC2).
    if ! printf '%s\n' "$tick_out" | grep -q "vote 0 (abstain) on unvoted proposal corr_id=TEST-CORR-1"; then
        echo "FAIL Test 8: expected a vote cast on TEST-CORR-1"
        printf '%s\n' "$tick_out"
        exit 1
    fi
    if ! grep -q '"kind":"vote".*"corr_id":"TEST-CORR-1"' "$TMP_AMB8"; then
        echo "FAIL Test 8: stub chump vote line not found in ambient"
        cat "$TMP_AMB8"
        exit 1
    fi
    echo "  ok Test 8: chump vote emitted for open proposal TEST-CORR-1"

    # Second tick run (fresh session, same corr_id) with CHUMP_FLEET_RECV_SIDE_V0
    # unset: inbox drain still runs (unconditional) but no vote is cast.
    printf '{"ts":"2026-05-30T00:00:02Z","event":"INTENT","session":"peer-x","kind":"decompose_request","gap_id":"META-TEST-2"}\n' \
        > "$TMP_LOCK8/inbox/${SESSION8}-gated.jsonl"
    set +e
    tick_out_gated="$(
        CHUMP_FLEET_RECV_SIDE_V0=0 \
        CHUMP_LOCK_DIR="$TMP_LOCK8" \
        CHUMP_SESSION_ID="${SESSION8}-gated" \
        CHUMP_STUB_AMBIENT="$TMP_AMB8" \
        PATH="$TMP_BIN8:$PATH" \
        bash "$SCRIPT" tick 2>&1 || true
    )"
    set -e
    if printf '%s\n' "$tick_out_gated" | grep -q "vote 0 (abstain)"; then
        echo "FAIL Test 8: vote cast even though CHUMP_FLEET_RECV_SIDE_V0=0"
        exit 1
    fi
    if ! printf '%s\n' "$tick_out_gated" | grep -q "items_read=1"; then
        echo "FAIL Test 8: inbox drain should still run when CHUMP_FLEET_RECV_SIDE_V0=0"
        printf '%s\n' "$tick_out_gated"
        exit 1
    fi
    echo "  ok Test 8: voting is feature-flag gated; inbox drain is not"

    rm -rf "$TMP_DIR8"
}

echo "test-decompose-loop: PASS"
