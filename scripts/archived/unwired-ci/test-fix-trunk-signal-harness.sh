#!/usr/bin/env bash
# scripts/ci/test-fix-trunk-signal-harness.sh — INFRA-4712 (INFRA-2342 slice)
#
# Validates scripts/dev/fix-trunk-signal-harness.sh:
#   1. Publishes a fix_trunk_test_signal entry to the URGENT-INBOX queue.
#   2. Logs the message ID + timestamp to its own harness log.
#   3. The message ID recorded in the log matches the one written to the
#      URGENT-INBOX entry (verification trail).
#   4. --gap-id / --body overrides flow through to the published entry.

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-4712 fix-trunk-signal-harness tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HARNESS="$REPO_ROOT/scripts/dev/fix-trunk-signal-harness.sh"
[[ -x "$HARNESS" ]] || { echo "FATAL: harness not executable at $HARNESS"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"
URGENT_INBOX="$FAKE/.chump-locks/URGENT-INBOX.jsonl"
HARNESS_LOG="$FAKE/.chump-locks/fix-trunk-signal-harness.log"

run_harness() {
    env CHUMP_REPO="$FAKE" \
        CHUMP_URGENT_INBOX="$URGENT_INBOX" \
        CHUMP_FIX_TRUNK_HARNESS_LOG="$HARNESS_LOG" \
        bash "$HARNESS" "$@"
}

# --- 1: default invocation publishes one entry -----------------------------
out="$(run_harness 2>&1)"
if [[ -f "$URGENT_INBOX" ]] && [[ "$(wc -l < "$URGENT_INBOX" | tr -d ' ')" == "1" ]]; then
    ok "harness publishes exactly one URGENT-INBOX entry"
else
    fail "harness did not publish exactly one URGENT-INBOX entry"
fi

entry="$(tail -1 "$URGENT_INBOX" 2>/dev/null)"
kind="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('kind',''))" "$entry" 2>/dev/null)"
if [[ "$kind" == "fix_trunk_test_signal" ]]; then
    ok "published entry has kind=fix_trunk_test_signal"
else
    fail "published entry kind mismatch (got: $kind)"
fi

urgency="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('urgency',''))" "$entry" 2>/dev/null)"
if [[ "$urgency" == "CRIT" ]]; then
    ok "published entry is CRIT urgency (visible on global inbox)"
else
    fail "published entry urgency mismatch (got: $urgency)"
fi

msg_id_inbox="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('message_id',''))" "$entry" 2>/dev/null)"
if [[ -n "$msg_id_inbox" ]]; then
    ok "published entry carries a non-empty message_id"
else
    fail "published entry message_id is empty"
fi

# --- 2: harness log carries the same message_id + a timestamp --------------
[[ -f "$HARNESS_LOG" ]] || fail "harness log file was not created"
log_line="$(tail -1 "$HARNESS_LOG" 2>/dev/null)"
msg_id_log="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('message_id',''))" "$log_line" 2>/dev/null)"
log_ts="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ts',''))" "$log_line" 2>/dev/null)"

if [[ -n "$msg_id_log" && "$msg_id_log" == "$msg_id_inbox" ]]; then
    ok "harness log message_id matches URGENT-INBOX message_id"
else
    fail "harness log message_id ($msg_id_log) does not match URGENT-INBOX message_id ($msg_id_inbox)"
fi

if [[ -n "$log_ts" ]]; then
    ok "harness log records a timestamp"
else
    fail "harness log missing timestamp"
fi

if echo "$out" | grep -q "$msg_id_inbox"; then
    ok "harness stdout echoes the published message_id for operator verification"
else
    fail "harness stdout did not echo the message_id"
fi

# --- 3: --gap-id / --body overrides flow through ----------------------------
run_harness --gap-id INFRA-9999 --body "custom body text" >/dev/null 2>&1
entry2="$(tail -1 "$URGENT_INBOX" 2>/dev/null)"
gap_id2="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('gap_id',''))" "$entry2" 2>/dev/null)"
body2="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('body',''))" "$entry2" 2>/dev/null)"

if [[ "$gap_id2" == "INFRA-9999" ]]; then
    ok "--gap-id override flows through to published entry"
else
    fail "--gap-id override not honored (got: $gap_id2)"
fi

if [[ "$body2" == "custom body text" ]]; then
    ok "--body override flows through to published entry"
else
    fail "--body override not honored (got: $body2)"
fi

if [[ "$(wc -l < "$URGENT_INBOX" | tr -d ' ')" == "2" ]]; then
    ok "second invocation appends (queue semantics preserved)"
else
    fail "second invocation did not append correctly"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
