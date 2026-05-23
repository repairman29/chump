#!/usr/bin/env bash
# scripts/ci/test-opus-message-hook.sh — INFRA-1797
#
# Verifies the SessionStart hook (ambient-context-inject.sh) surfaces unread
# opus-message inbox entries with the documented shape:
#   ═══ Opus inbox (N unread) ═══
#   <up to 3 latest previews>
#
# Assertions:
#   1. 0 unread → block absent
#   2. 2 unread session-targeted → block shows "2 unread", both previews
#   3. all-opus broadcast picked up alongside session inbox
#   4. read messages (read_at != null) excluded from count
#   5. CHUMP_OPUS_INBOX_HOOK=0 disables the block

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"

if [[ ! -x "$HOOK" ]]; then
    echo "FAIL: $HOOK not executable"
    exit 1
fi

# Isolated fixture
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_OPUS_INBOX_DIR="$TMP/inbox"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export REPO_ROOT="$TMP"   # hook reads REPO_ROOT for fallback paths
mkdir -p "$CHUMP_OPUS_INBOX_DIR" "$TMP/.chump-locks"
touch "$CHUMP_AMBIENT_LOG"

failures=0
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if ! printf '%s' "$haystack" | grep -q -- "$needle"; then
        echo "FAIL: $desc"
        echo "       want substring: $needle"
        failures=$((failures + 1))
    fi
}
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -q -- "$needle"; then
        echo "FAIL: $desc"
        echo "       unexpected substring: $needle"
        failures=$((failures + 1))
    fi
}

# ── Helper: extract the additionalContext string from the hook's JSON output ─
run_hook() {
    local hook_session_id="${1:-test-session-1}"
    CHUMP_SESSION_ID="$hook_session_id" \
        bash "$HOOK" SessionStart 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

# ── 1. zero unread → block absent ───────────────────────────────────────────
out="$(run_hook test-session-1)"
assert_not_contains "block absent when 0 unread" "$out" "Opus inbox"

# ── 2. seed 2 unread session-targeted messages → block shows 2 ──────────────
mkdir -p "$CHUMP_OPUS_INBOX_DIR"
cat > "$CHUMP_OPUS_INBOX_DIR/session_test-session-1.jsonl" <<'JSONL'
{"id":"msg001","ts":"2026-05-23T01:00:00Z","from":"session:sender-A","to":"session:test-session-1","body":"hand-off note: continue at §3 of inventory","ref":"pr:2386","read_at":null}
{"id":"msg002","ts":"2026-05-23T02:00:00Z","from":"session:sender-B","to":"session:test-session-1","body":"flagging audit drift on INFRA-1717","ref":"gap:INFRA-1717","read_at":null}
JSONL
out="$(run_hook test-session-1)"
assert_contains "block shows 2 unread" "$out" "Opus inbox (2 unread)"
assert_contains "preview 1 body present" "$out" "hand-off note"
assert_contains "preview 2 body present" "$out" "flagging audit drift"
assert_contains "preview includes msg-id" "$out" "msg002"

# ── 3. all-opus broadcast picked up alongside session inbox ─────────────────
cat > "$CHUMP_OPUS_INBOX_DIR/all-opus.jsonl" <<'JSONL'
{"id":"msg003","ts":"2026-05-23T03:00:00Z","from":"session:sender-C","to":"all-opus","body":"broadcast: rebasing main in 5min","ref":"","read_at":null}
JSONL
out="$(run_hook test-session-1)"
assert_contains "block now shows 3 unread" "$out" "Opus inbox (3 unread)"
assert_contains "broadcast body present" "$out" "broadcast: rebasing main"

# ── 4. read messages excluded ───────────────────────────────────────────────
cat > "$CHUMP_OPUS_INBOX_DIR/session_test-session-2.jsonl" <<'JSONL'
{"id":"msg004","ts":"2026-05-23T04:00:00Z","from":"session:sender-D","to":"session:test-session-2","body":"already-read message","ref":"","read_at":"2026-05-23T04:30:00Z"}
{"id":"msg005","ts":"2026-05-23T05:00:00Z","from":"session:sender-E","to":"session:test-session-2","body":"actually unread","ref":"","read_at":null}
JSONL
out="$(run_hook test-session-2)"
# Should count only the 1 unread (msg005) plus the 1 unread broadcast (msg003)
assert_contains "read messages excluded from count" "$out" "Opus inbox (2 unread)"
assert_contains "unread message body present" "$out" "actually unread"
assert_not_contains "read message body excluded" "$out" "already-read message"

# ── 5. CHUMP_OPUS_INBOX_HOOK=0 disables ─────────────────────────────────────
CHUMP_OPUS_INBOX_HOOK=0 CHUMP_SESSION_ID=test-session-1 \
    bash "$HOOK" SessionStart 2>/dev/null \
    | python3 -c 'import json,sys; out=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; sys.exit(0 if "Opus inbox" not in out else 1)' \
    || { echo "FAIL: CHUMP_OPUS_INBOX_HOOK=0 did not disable block"; failures=$((failures + 1)); }

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1797: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1797: SessionStart hook surfaces opus-message inbox correctly"
