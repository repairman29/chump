#!/usr/bin/env bash
# scripts/ci/test-a2a-delivery-receipts.sh — INFRA-1944
#
# Smoke test: broadcast.sh / chump-inbox.sh delivery-confirmation receipts
# (slice A of INFRA-1862). Verifies:
#   (a) broadcast.sh --to writes a {ts,corr_id,to,expires_at} side-record to
#       .chump-locks/inbox/<sender>-sent-pending.jsonl
#   (b) chump-inbox.sh read consumes a message addressed to a live recipient
#       and emits kind=a2a_msg_delivered {ts,corr_id,recipient,read_at} to
#       ambient.jsonl
#   (c) a2a-delivery-tail.sh --corr-id <id> --timeout N returns 0 once that
#       event lands
#   (d) a message sent to a fixture inbox that nobody reads produces no
#       kind=a2a_msg_delivered event, and a2a-delivery-tail.sh returns 1
#       after the timeout elapses
#   (e) broadcast.sh --await blocks until delivery and returns 0; a send to
#       an unread fixture inbox with --await returns 2 on timeout

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
INBOX="$REPO_ROOT/scripts/coord/chump-inbox.sh"
TAIL="$REPO_ROOT/scripts/coord/a2a-delivery-tail.sh"

[[ -x "$BROADCAST" ]] || { echo "[FAIL] broadcast.sh not executable at $BROADCAST" >&2; exit 1; }
[[ -f "$INBOX" ]] || { echo "[FAIL] chump-inbox.sh not found at $INBOX" >&2; exit 1; }
[[ -x "$TAIL" ]] || { echo "[FAIL] a2a-delivery-tail.sh not executable at $TAIL" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/.chump-locks/inbox"
git -C "$TMP" init -q "$SANDBOX"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

LOCK_DIR="$SANDBOX/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"

run_broadcast() {
    ( cd "$SANDBOX" && CHUMP_SESSION_ID="alice" "$BROADCAST" "$@" ) 2>&1
}

run_inbox() {
    local session="$1"; shift
    ( cd "$SANDBOX" && CHUMP_SESSION_ID="$session" "$INBOX" "$@" ) 2>&1
}

# ── (a) --to send writes a sent-pending side-record ──────────────────────────
run_broadcast --to bob --corr live-corr-1 WARN "hello bob" >/dev/null
PENDING_FILE="$LOCK_DIR/inbox/alice-sent-pending.jsonl"
[[ -f "$PENDING_FILE" ]] || fail "(a) sent-pending file not created at $PENDING_FILE"
grep -q "\"corr_id\": *\"live-corr-1\"" "$PENDING_FILE" \
    || fail "(a) sent-pending record missing corr_id=live-corr-1: $(cat "$PENDING_FILE")"
grep -q "\"to\": *\"bob\"" "$PENDING_FILE" \
    || fail "(a) sent-pending record missing to=bob: $(cat "$PENDING_FILE")"
grep -q "expires_at" "$PENDING_FILE" \
    || fail "(a) sent-pending record missing expires_at: $(cat "$PENDING_FILE")"
ok "(a) --to send writes sent-pending receipt with corr_id/to/expires_at"

# ── (b) recipient read emits kind=a2a_msg_delivered ───────────────────────────
[[ -f "$LOCK_DIR/inbox/bob.jsonl" ]] || fail "(b) bob's inbox file was not written"
run_inbox bob read >/dev/null

DELIVERED_LINE="$(grep '"kind": *"a2a_msg_delivered"' "$AMBIENT" | grep "live-corr-1" || true)"
[[ -n "$DELIVERED_LINE" ]] || fail "(b) no a2a_msg_delivered event for live-corr-1 in ambient: $(cat "$AMBIENT")"
echo "$DELIVERED_LINE" | grep -q '"recipient": *"bob"' \
    || fail "(b) a2a_msg_delivered missing recipient=bob: $DELIVERED_LINE"
echo "$DELIVERED_LINE" | grep -q "read_at" \
    || fail "(b) a2a_msg_delivered missing read_at: $DELIVERED_LINE"
ok "(b) chump-inbox.sh read emits kind=a2a_msg_delivered for live recipient"

# ── (c) a2a-delivery-tail.sh confirms delivery ────────────────────────────────
( cd "$SANDBOX" && LOCK_DIR="$LOCK_DIR" "$TAIL" --corr-id live-corr-1 --timeout 2 ) \
    || fail "(c) a2a-delivery-tail.sh did not confirm delivered corr_id=live-corr-1"
ok "(c) a2a-delivery-tail.sh returns 0 for a delivered corr_id"

# ── (d) fixture inbox that nobody reads: no delivery event, tail returns 1 ───
run_broadcast --to fixture-inbox --corr fixture-corr-1 WARN "nobody reads this" >/dev/null
[[ -f "$LOCK_DIR/inbox/fixture-inbox.jsonl" ]] || fail "(d) fixture-inbox.jsonl not written"

if grep -q "fixture-corr-1" "$AMBIENT" 2>/dev/null && grep '"kind": *"a2a_msg_delivered"' "$AMBIENT" | grep -q "fixture-corr-1"; then
    fail "(d) unexpected a2a_msg_delivered for fixture-corr-1 (nobody read it): $(cat "$AMBIENT")"
fi
ok "(d1) no a2a_msg_delivered event for the unread fixture-inbox message"

set +e
( cd "$SANDBOX" && LOCK_DIR="$LOCK_DIR" "$TAIL" --corr-id fixture-corr-1 --timeout 2 )
TAIL_RC=$?
set -e
[[ "$TAIL_RC" -eq 1 ]] || fail "(d2) a2a-delivery-tail.sh should return 1 on timeout, got rc=$TAIL_RC"
ok "(d2) a2a-delivery-tail.sh returns 1 after timeout for an unread message"

# ── (e) broadcast.sh --await blocks until delivery / times out on no read ────
(
    cd "$SANDBOX"
    ( sleep 1; CHUMP_SESSION_ID="carol" "$INBOX" read >/dev/null 2>&1 ) &
    CHUMP_SESSION_ID="alice" "$BROADCAST" --to carol --corr await-corr-1 --await 5 WARN "await me"
)
AWAIT_RC=$?
[[ "$AWAIT_RC" -eq 0 ]] || fail "(e1) broadcast.sh --await should return 0 once delivered, got rc=$AWAIT_RC"
ok "(e1) broadcast.sh --await returns 0 once the recipient reads"

set +e
( cd "$SANDBOX" && CHUMP_SESSION_ID="alice" "$BROADCAST" --to nobody-home --corr await-corr-2 --await 2 WARN "await timeout" >/dev/null 2>&1 )
AWAIT_TIMEOUT_RC=$?
set -e
[[ "$AWAIT_TIMEOUT_RC" -eq 2 ]] || fail "(e2) broadcast.sh --await should return 2 on timeout, got rc=$AWAIT_TIMEOUT_RC"
ok "(e2) broadcast.sh --await returns 2 when nobody reads within the timeout"

echo ""
echo "All tests passed."
