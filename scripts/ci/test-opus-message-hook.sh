#!/usr/bin/env bash
# scripts/ci/test-opus-message-hook.sh — INFRA-1797
#
# Verifies the SessionStart hook (ambient-context-inject.sh) surfaces unread
# entries from the canonical INFRA-1115 inbox (.chump-locks/inbox/<session>.jsonl
# + .cursor) with the documented shape:
#   ═══ Inbox (N unread) ═══
#   <up to 3 latest previews>
#
# Unread = lines past the byte offset stored in <session>.cursor.

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

export CHUMP_INBOX_DIR="$TMP/inbox"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export REPO_ROOT="$TMP"
mkdir -p "$CHUMP_INBOX_DIR" "$TMP/.chump-locks"
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

run_hook() {
    local hook_session_id="${1:-test-session-1}"
    CHUMP_SESSION_ID="$hook_session_id" \
        bash "$HOOK" SessionStart 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

# ── 1. zero unread → block absent ───────────────────────────────────────────
out="$(run_hook test-session-1)"
assert_not_contains "block absent when 0 unread" "$out" "Inbox ("

# ── 2. 2 messages in inbox + no cursor → both unread ───────────────────────
cat > "$CHUMP_INBOX_DIR/test-session-1.jsonl" <<'JSONL'
{"event":"WARN","session":"orchestrator-opus-2026-05-23","ts":"2026-05-23T01:00:00Z","corr_id":"branch:foo","reason":"hand-off note: continue at section 3 of inventory","to":"test-session-1"}
{"event":"INTENT","session":"curator-opus-handoff-2026-05-23","ts":"2026-05-23T02:00:00Z","corr_id":"gap:INFRA-1717","reason":"flagging audit drift on INFRA-1717","to":"test-session-1"}
JSONL
out="$(run_hook test-session-1)"
assert_contains "block shows 2 unread" "$out" "Inbox (2 unread)"
assert_contains "preview 1 body present" "$out" "hand-off note"
assert_contains "preview 2 body present" "$out" "flagging audit drift"
assert_contains "shows event kind" "$out" "WARN"
assert_contains "shows sender session" "$out" "orchestrator-opus-2026-05-23"

# ── 3. cursor at end-of-file → 0 unread ─────────────────────────────────────
file_size=$(wc -c < "$CHUMP_INBOX_DIR/test-session-1.jsonl" | tr -d ' ')
echo "$file_size" > "$CHUMP_INBOX_DIR/test-session-1.cursor"
out="$(run_hook test-session-1)"
assert_not_contains "block absent when cursor at EOF" "$out" "Inbox ("

# ── 4. cursor at byte 0 → all messages unread ───────────────────────────────
echo "0" > "$CHUMP_INBOX_DIR/test-session-1.cursor"
out="$(run_hook test-session-1)"
assert_contains "cursor=0 shows all 2 unread" "$out" "Inbox (2 unread)"

# ── 5. cursor mid-file → only later messages unread ────────────────────────
# Set cursor just after the first line (before the second)
first_line_bytes=$(head -1 "$CHUMP_INBOX_DIR/test-session-1.jsonl" | wc -c | tr -d ' ')
echo "$first_line_bytes" > "$CHUMP_INBOX_DIR/test-session-1.cursor"
out="$(run_hook test-session-1)"
assert_contains "cursor past line 1 shows 1 unread" "$out" "Inbox (1 unread)"
assert_contains "remaining message body present" "$out" "flagging audit drift"
assert_not_contains "consumed message body absent" "$out" "hand-off note"

# ── 6. CHUMP_OPUS_INBOX_HOOK=0 disables ─────────────────────────────────────
echo "0" > "$CHUMP_INBOX_DIR/test-session-1.cursor"
CHUMP_OPUS_INBOX_HOOK=0 CHUMP_SESSION_ID=test-session-1 \
    bash "$HOOK" SessionStart 2>/dev/null \
    | python3 -c 'import json,sys; out=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; sys.exit(0 if "Inbox (" not in out else 1)' \
    || { echo "FAIL: CHUMP_OPUS_INBOX_HOOK=0 did not disable block"; failures=$((failures + 1)); }

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1797: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1797: SessionStart hook surfaces canonical INFRA-1115 inbox correctly"
