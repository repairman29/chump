#!/usr/bin/env bash
# scripts/ci/test-opus-message.sh — INFRA-1796
#
# Smoke test for the opus-message v0 inbox CLI. Asserts:
#   1. send creates a JSONL line in the recipient's inbox with the right shape
#   2. list shows the message
#   3. list --unread shows it (read_at:null)
#   4. mark-read flips read_at to a timestamp
#   5. list --unread no longer shows it after mark-read
#   6. opus_message_sent ambient event emitted
#   7. gap-addressed recipient routes to the lease holder's session
#   8. all-opus broadcast inbox separate from per-session inbox

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/scripts/coord/opus-message.sh"

if [[ ! -x "$CLI" ]]; then
    echo "FAIL: $CLI not executable"
    exit 1
fi

# Isolated test fixture: temp dirs for inbox + ambient + leases.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_OPUS_INBOX_DIR="$TMP/inbox"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export CHUMP_LEASE_DIR="$TMP/leases"
mkdir -p "$CHUMP_OPUS_INBOX_DIR" "$CHUMP_LEASE_DIR"
touch "$CHUMP_AMBIENT_LOG"

failures=0
assert() {
    local desc="$1"; shift
    if ! "$@"; then
        echo "FAIL: $desc"
        failures=$((failures + 1))
    fi
}

# ── 1. send + list round-trip on session: recipient ─────────────────────────
msg_id=$("$CLI" send --to session:test-session-1 --from session:sender-1 \
    --body "round-trip hello" --ref pr:9999)

if [[ -z "$msg_id" ]]; then
    echo "FAIL: send returned no message id"
    failures=$((failures + 1))
fi

inbox_file="$CHUMP_OPUS_INBOX_DIR/session_test-session-1.jsonl"
assert "session inbox file exists" test -f "$inbox_file"
assert "inbox has the message body" grep -q "round-trip hello" "$inbox_file"
assert "inbox has the from field" grep -q "session:sender-1" "$inbox_file"
assert "inbox has read_at:null" grep -q '"read_at": null\|"read_at":null' "$inbox_file"
assert "msg_id present in inbox line" grep -q "$msg_id" "$inbox_file"

# ── 2. list --unread shows the unread message ───────────────────────────────
unread_out=$("$CLI" list --for session:test-session-1 --unread)
echo "$unread_out" | grep -q "$msg_id" || {
    echo "FAIL: list --unread did not show $msg_id"
    echo "  output: $unread_out"
    failures=$((failures + 1))
}
echo "$unread_out" | grep -q "round-trip hello" || {
    echo "FAIL: list --unread did not show body"
    failures=$((failures + 1))
}

# ── 3. mark-read flips read_at ──────────────────────────────────────────────
mark_out=$("$CLI" mark-read "$msg_id" --for session:test-session-1)
echo "$mark_out" | grep -q "marked $msg_id read" || {
    echo "FAIL: mark-read did not confirm"
    failures=$((failures + 1))
}

# After mark-read, read_at should NOT be null.
if grep -q "\"id\": \"$msg_id\".*\"read_at\": null" "$inbox_file"; then
    echo "FAIL: mark-read left read_at null"
    failures=$((failures + 1))
fi
if ! grep -q "\"id\": \"$msg_id\".*\"read_at\": \"" "$inbox_file"; then
    echo "FAIL: mark-read did not set read_at to a timestamp"
    failures=$((failures + 1))
fi

# ── 4. list --unread no longer shows it ─────────────────────────────────────
unread_after=$("$CLI" list --for session:test-session-1 --unread)
if echo "$unread_after" | grep -q "$msg_id"; then
    echo "FAIL: read message still appears in list --unread"
    failures=$((failures + 1))
fi

# ── 5. ambient event emitted ────────────────────────────────────────────────
assert "opus_message_sent emitted" \
    grep -q '"kind":"opus_message_sent"\|"kind": "opus_message_sent"' "$CHUMP_AMBIENT_LOG"

# ── 6. all-opus broadcast inbox separate from per-session ───────────────────
"$CLI" send --to all-opus --from session:sender-2 --body "broadcast hello" >/dev/null
broadcast_inbox="$CHUMP_OPUS_INBOX_DIR/all-opus.jsonl"
assert "all-opus inbox created" test -f "$broadcast_inbox"
assert "all-opus inbox has body" grep -q "broadcast hello" "$broadcast_inbox"
# Confirm broadcast went to a different file than session inbox.
if [[ "$inbox_file" == "$broadcast_inbox" ]]; then
    echo "FAIL: broadcast inbox path collided with session inbox"
    failures=$((failures + 1))
fi

# ── 7. gap-addressed routing — falls back to gap-slot when no lease ─────────
"$CLI" send --to gap:INFRA-9001 --from session:sender-3 --body "no-lease gap msg" >/dev/null
gap_inbox="$CHUMP_OPUS_INBOX_DIR/gap_INFRA-9001.jsonl"
assert "gap-slot inbox created when no lease holds the gap" test -f "$gap_inbox"

# ── 7b. gap-addressed routing — routes to lease session when lease exists ───
# Synthesize a lease file mimicking chump-claim shape.
lease_file="$CHUMP_LEASE_DIR/claim-infra-9002-12345-1700000000.json"
cat > "$lease_file" <<'JSON'
{"session_id":"claim-infra-9002-12345-1700000000","gap_id":"INFRA-9002","purpose":"gap:INFRA-9002","expires_at":"2099-01-01T00:00:00Z"}
JSON

"$CLI" send --to gap:INFRA-9002 --from session:sender-4 --body "lease-routed msg" >/dev/null
routed_inbox="$CHUMP_OPUS_INBOX_DIR/session_claim-infra-9002-12345-1700000000.jsonl"
assert "gap:INFRA-9002 routed to lease holder's session inbox" test -f "$routed_inbox"
assert "routed message body present" grep -q "lease-routed msg" "$routed_inbox"

# ── 8. mark-read of unknown id fails non-zero ───────────────────────────────
if "$CLI" mark-read nonexistent-id --for session:test-session-1 2>/dev/null; then
    echo "FAIL: mark-read of unknown id should exit non-zero"
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1796: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1796: opus-message v0 send/list/mark-read + gap-routing + all-opus broadcast intact"
