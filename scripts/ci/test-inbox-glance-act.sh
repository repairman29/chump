#!/usr/bin/env bash
# test-inbox-glance-act.sh — INFRA-1798 smoke test.
#
# Drives a REAL curator loop (scripts/coord/ci-audit-loop.sh tick) — not a
# hand-written fixture of the glance library — against a sandbox with 1
# unread FEEDBACK/proposal message queued in the inbox. Asserts the AC5
# 3-part outcome:
#   (a) the proposal is read (inbox cursor advances; kind=inbox_advance fires)
#   (b) a chump vote is emitted for it
#   (c) an inbox_advance event lands in ambient.jsonl
#
# A stub `chump` binary on PATH keeps (b) deterministic without depending on
# a real CLI/DB — it records the call the same way src/commands/vote.rs does
# (emits a `kind=vote` ambient line), which is what the tally side reads.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "  ok: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

LOOP_SCRIPT="scripts/coord/ci-audit-loop.sh"
if [[ ! -x "$LOOP_SCRIPT" ]]; then
    echo "FAIL: $LOOP_SCRIPT not executable"
    exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

LOCK_DIR="$SANDBOX/.chump-locks"
BIN_DIR="$SANDBOX/bin"
SESSION="test-glance-ci-audit"
mkdir -p "$LOCK_DIR/inbox" "$BIN_DIR"

# 1 unread proposal, delivered as a targeted inbox message (the realistic
# path: a peer broadcasts FEEDBACK --to this session).
printf '{"ts":"2026-08-12T00:00:00Z","event":"FEEDBACK","session":"peer-opus","kind":"proposal","corr_id":"INFRA-1798-TEST-CORR","to":"%s","body":"should the fleet adopt X?"}\n' \
    "$SESSION" > "$LOCK_DIR/inbox/${SESSION}.jsonl"

# The proposal must also be visible on the ambient stream (that's where the
# glance lib scans for open corr_ids to vote on) — the inbox delivery and
# the ambient broadcast are two sides of the same broadcast.sh call in
# production; reproduce both here.
printf '{"ts":"2026-08-12T00:00:00Z","event":"FEEDBACK","kind":"proposal","corr_id":"INFRA-1798-TEST-CORR","body":"should the fleet adopt X?"}\n' \
    > "$LOCK_DIR/ambient.jsonl"

# Stub `chump vote` — records the call as a kind=vote ambient line, same
# shape src/commands/vote.rs emits (this is what the tally/audit side reads).
cat > "$BIN_DIR/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "vote" ]]; then
    corr="$2"; v="$3"; shift 3
    reason=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" == "--reason" ]] && reason="$2"
        shift
    done
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":%s,"rationale":"%s","session":"%s"}\n' \
        "$ts" "$corr" "$v" "$reason" "${CHUMP_SESSION_ID:-unknown}" >> "$CHUMP_STUB_AMBIENT"
fi
exit 0
STUB
chmod +x "$BIN_DIR/chump"

# ── Drive the real loop's tick — the mandatory first step per AC1/AC2 ─────
set +e
TICK_OUT="$(
    CHUMP_FLEET_RECV_SIDE_V0=1 \
    CHUMP_SESSION_ID="$SESSION" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$LOCK_DIR/ambient.jsonl" \
    CHUMP_STUB_AMBIENT="$LOCK_DIR/ambient.jsonl" \
    PATH="$BIN_DIR:$PATH" \
    bash "$LOOP_SCRIPT" tick 2>&1
)"
set -e

echo "$TICK_OUT" | sed 's/^/    /'

# (a) the proposal is read — Glance phase ran + drained the inbox item.
if echo "$TICK_OUT" | grep -q "## Glance: inbox drain + act"; then
    pass "Glance phase ran as first step of tick"
else
    fail "Glance phase header not found in tick output"
fi

if echo "$TICK_OUT" | grep -q "items_read=1"; then
    pass "1 inbox item read"
else
    fail "expected items_read=1"
fi

cursor_file="$LOCK_DIR/inbox/${SESSION}.cursor"
if [[ -f "$cursor_file" ]]; then
    pass "inbox cursor file created (chump-inbox.sh read advanced it)"
else
    fail "cursor file not created at $cursor_file"
fi

# (b) a chump vote is emitted for it.
if echo "$TICK_OUT" | grep -q "vote 0 (abstain) on unvoted proposal corr_id=INFRA-1798-TEST-CORR"; then
    pass "glance decided to vote on the open proposal"
else
    fail "expected a vote decision for corr_id=INFRA-1798-TEST-CORR"
fi

if grep -q '"kind":"vote"' "$LOCK_DIR/ambient.jsonl" && \
   grep '"kind":"vote"' "$LOCK_DIR/ambient.jsonl" | grep -q '"corr_id":"INFRA-1798-TEST-CORR"'; then
    pass "chump vote emitted for corr_id=INFRA-1798-TEST-CORR"
else
    fail "no kind=vote ambient line for corr_id=INFRA-1798-TEST-CORR"
    cat "$LOCK_DIR/ambient.jsonl"
fi

# (c) an inbox_advance event lands in ambient.jsonl (chump-inbox.sh's own emit).
if grep -q '"kind":"inbox_advance"' "$LOCK_DIR/ambient.jsonl"; then
    pass "kind=inbox_advance emitted to ambient.jsonl"
else
    fail "no kind=inbox_advance event found"
    cat "$LOCK_DIR/ambient.jsonl"
fi

# ── Idempotency: a second tick with no new inbox items casts no duplicate vote ──
set +e
TICK_OUT_2="$(
    CHUMP_FLEET_RECV_SIDE_V0=1 \
    CHUMP_SESSION_ID="$SESSION" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$LOCK_DIR/ambient.jsonl" \
    CHUMP_STUB_AMBIENT="$LOCK_DIR/ambient.jsonl" \
    PATH="$BIN_DIR:$PATH" \
    bash "$LOOP_SCRIPT" tick 2>&1
)"
set -e
if echo "$TICK_OUT_2" | grep -q "items_read=0"; then
    pass "second tick: no new inbox items (items_read=0)"
else
    fail "second tick should report items_read=0"
fi
if echo "$TICK_OUT_2" | grep -q "vote 0 (abstain)"; then
    fail "second tick re-voted on an already-voted proposal (should be a no-op)"
else
    pass "second tick does not re-vote on the already-voted proposal"
fi

echo
echo "test-inbox-glance-act: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
