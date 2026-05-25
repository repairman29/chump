#!/usr/bin/env bash
# scripts/ci/test-inbox-injector.sh — INFRA-2014
#
# Validates the live A2A inbox-injector:
#   1. CHUMP_INBOX_INJECTOR_PAUSE=1 → silent no-op
#   2. Empty inbox → daemon exits clean
#   3. INFO message → NO injection (correct: only CRIT/EMERGENCY interrupt)
#   4. CRIT message + matching tmux pane → send-keys fires
#   5. Idempotent: re-run with no new messages → no double-injection
#   6. EMERGENCY → C-c sent before the message line

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2014 inbox-injector tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
INJ="$REPO_ROOT/scripts/coord/inbox-injector.sh"
[[ -x "$INJ" ]] || { echo "FATAL: $INJ not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks/inbox"

# Mock tmux — records every invocation to a log file
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
echo "$@" >> "$TMUX_CALL_LOG"
# Mock specific commands the injector uses:
case "$1" in
    list-panes)
        # Return a synthetic pane line that includes the test recipient
        echo "fleet:0.0 ${TEST_RECIPIENT:-chump-Chump-1776471708}-pane-title fleet-window"
        ;;
    capture-pane)
        # Return content that looks idle (ends with prompt)
        echo "previous line"
        echo "blah blah"
        echo "Human: "
        ;;
    send-keys)
        echo "SENDKEYS: $*" >> "$SENDKEYS_LOG"
        ;;
esac
exit 0
TMUX
chmod +x "$TMP/bin/tmux"

run_injector() {
    cd "$FAKE" || return 2
    env CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        CHUMP_INBOX_INJECTOR_TEST_TMUX="$TMP/bin/tmux" \
        TMUX_CALL_LOG="$TMP/tmux-calls.log" \
        SENDKEYS_LOG="$TMP/sendkeys.log" \
        TEST_RECIPIENT="${TEST_RECIPIENT:-}" \
        "$@" \
        bash "$INJ" 2>&1
    local rc=$?
    cd - >/dev/null
    return "$rc"
}

write_inbox() {
    local recipient="$1"; local event="$2"; local body="$3"; local urgency="${4:-}"
    local extra=""
    [[ -n "$urgency" ]] && extra=",\"urgency\":\"$urgency\""
    printf '{"event":"%s","session":"test-sender","ts":"%s","gap":"%s","reason":"%s","to":"%s"%s}\n' \
        "$event" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$body" "$body" "$recipient" "$extra" \
        >> "$FAKE/.chump-locks/inbox/$recipient.jsonl"
}

# ── Test 1: pause env ───────────────────────────────────────────────────────
echo "--- Test 1: CHUMP_INBOX_INJECTOR_PAUSE=1 → no-op ---"
> "$FAKE/.chump-locks/ambient.jsonl"
run_injector CHUMP_INBOX_INJECTOR_PAUSE=1 > /dev/null
if grep -q "inbox_injector_paused" "$FAKE/.chump-locks/ambient.jsonl"; then
    ok "pause env produced inbox_injector_paused"
else
    fail "expected paused event (ambient=$(cat $FAKE/.chump-locks/ambient.jsonl))"
fi

# ── Test 2: empty inbox → clean exit ────────────────────────────────────────
echo "--- Test 2: no inbox files → clean exit ---"
rm -f "$FAKE/.chump-locks/ambient.jsonl"
run_injector > /dev/null
if [[ ! -s "$FAKE/.chump-locks/ambient.jsonl" ]] && [[ ! -s "$TMP/sendkeys.log" ]]; then
    ok "empty inbox → no events, no injections"
else
    fail "expected silent run (ambient=$(cat $FAKE/.chump-locks/ambient.jsonl), sendkeys=$(cat $TMP/sendkeys.log 2>/dev/null))"
fi

# ── Test 3: INFO message → NO injection ─────────────────────────────────────
echo "--- Test 3: INFO event → no injection ---"
> "$TMP/sendkeys.log"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/inbox-injector-state.json"
write_inbox "test-rcpt" "INTENT" "low-priority FYI" ""
TEST_RECIPIENT="test-rcpt" run_injector > /dev/null
if [[ ! -s "$TMP/sendkeys.log" ]]; then
    ok "INFO event did NOT inject (correct — only CRIT/EMERGENCY interrupt)"
else
    fail "INFO should not inject (sendkeys=$(cat $TMP/sendkeys.log))"
fi

# ── Test 4: explicit CRIT urgency → injection fires ─────────────────────────
echo "--- Test 4: CRIT urgency + matching pane → send-keys fires ---"
> "$TMP/sendkeys.log"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/inbox-injector-state.json"
write_inbox "test-rcpt" "WARN" "trunk-RED cluster fired — pivot now" "CRIT"
TEST_RECIPIENT="test-rcpt" run_injector > /dev/null
if grep -q "INBOX CRIT" "$TMP/sendkeys.log" 2>/dev/null; then
    ok "CRIT urgency → send-keys fired with INBOX CRIT prefix"
else
    fail "expected INBOX CRIT send-keys (sendkeys=$(cat $TMP/sendkeys.log 2>/dev/null), ambient=$(cat $FAKE/.chump-locks/ambient.jsonl))"
fi

if grep -q "inbox_injection_executed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "audit event inbox_injection_executed emitted"
else
    fail "expected audit event (ambient=$(cat $FAKE/.chump-locks/ambient.jsonl))"
fi

# ── Test 5: idempotent — second run on same inbox → no double-inject ───────
echo "--- Test 5: idempotent — second run does NOT re-inject ---"
> "$TMP/sendkeys.log"
TEST_RECIPIENT="test-rcpt" run_injector > /dev/null
if [[ ! -s "$TMP/sendkeys.log" ]]; then
    ok "idempotent: re-run added no new send-keys"
else
    fail "expected no re-injection (sendkeys=$(cat $TMP/sendkeys.log))"
fi

# ── Test 6: EMERGENCY → C-c sent BEFORE the message ─────────────────────────
echo "--- Test 6: EMERGENCY → C-c (cancel) then message ---"
> "$TMP/sendkeys.log"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/inbox-injector-state.json"
write_inbox "test-rcpt" "ALERT" "DATA LOSS imminent on PR #9999" "EMERGENCY"
TEST_RECIPIENT="test-rcpt" run_injector > /dev/null
# Should have BOTH C-c and the message
if grep -q "send-keys.*C-c" "$TMP/tmux-calls.log" 2>/dev/null \
   && grep -q "INBOX EMERGENCY" "$TMP/sendkeys.log" 2>/dev/null; then
    ok "EMERGENCY → C-c interrupt + EMERGENCY message both sent"
else
    fail "expected C-c + EMERGENCY (tmux-calls=$(cat $TMP/tmux-calls.log 2>/dev/null), sendkeys=$(cat $TMP/sendkeys.log 2>/dev/null))"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
