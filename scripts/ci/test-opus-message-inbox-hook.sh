#!/usr/bin/env bash
# scripts/ci/test-opus-message-inbox-hook.sh — INFRA-1797 smoke test.
#
# Different surface from test-opus-message-hook.sh (which tests INFRA-1800's
# canonical .chump-locks/inbox/ surface). This test verifies the INFRA-1797
# block that surfaces .chump-locks/opus-inbox/ — the addressed-async DM
# channel from INFRA-1796 — at SessionStart.
#
# Asserts:
#   - '═══ Opus inbox (N unread) ═══' header rendered when unread > 0
#   - 3 latest unread message previews shown (id/from/to/ref + body line)
#   - already-read messages (read_at set) NOT previewed
#   - CHUMP_OPUS_INBOX_HOOK=0 bypass silences the output
#   - missing opus-inbox dir → silent skip
#   - read-only invariant: hook does NOT mark messages read

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.chump-locks/opus-inbox"

# Fixture: 3 messages — 1 read + 2 unread.
cat > "$SANDBOX/.chump-locks/opus-inbox/all-opus.jsonl" <<'EOF'
{"id":"m001","ts":"2026-05-29T20:00:00Z","from":"opusA","to":"opusB","ref":"INFRA-2001","body":"already read message body"}
{"id":"m002","ts":"2026-05-29T21:00:00Z","from":"opusC","to":"opusB","ref":"INFRA-2042","body":"unread body about INFRA-2042"}
{"id":"m003","ts":"2026-05-29T22:00:00Z","from":"opusD","to":"opusB","ref":"INFRA-2087","body":"unread body about cascade-break"}
EOF
python3 -c "
import json
p = '$SANDBOX/.chump-locks/opus-inbox/all-opus.jsonl'
with open(p) as f:
    rows = [json.loads(l) for l in f if l.strip()]
rows[0]['read_at'] = '2026-05-29T20:30:00Z'
with open(p, 'w') as f:
    for m in rows:
        f.write(json.dumps(m) + '\n')
"

run_hook() {
    # The hook script overrides REPO_ROOT with `git rev-parse`. Use the
    # CHUMP_OPUS_INBOX_DIR override directly (matches the hook block's
    # env-var precedence) to point at the sandbox inbox.
    CHUMP_OPUS_INBOX_DIR="$SANDBOX/.chump-locks/opus-inbox" \
        CHUMP_SESSION_ID="opusB" CHUMP_OPUS_INBOX_HOOK="${CHUMP_OPUS_INBOX_HOOK:-1}" \
        CHUMP_A2A_INBOX_INJECT=0 \
        bash scripts/coord/ambient-context-inject.sh SessionStart 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('hookSpecificOutput', {}).get('additionalContext', ''))
except Exception:
    pass
"
}

# ── Test 1: 2 unread → '2 unread' header + previews ────────────────────────
echo ""
echo "Test 1: unread messages render '2 unread' header"
out=$(run_hook || true)
if echo "$out" | grep -q "Opus inbox (2 unread)"; then
    pass "header '2 unread' present"
else
    fail "header missing — got: $(echo "$out" | head -3)"
fi

# ── Test 2: unread previews include m002 + m003 ────────────────────────────
echo ""
echo "Test 2: unread previews include the 2 unread messages"
if echo "$out" | grep -q "m002" && echo "$out" | grep -q "from=opusC" \
   && echo "$out" | grep -q "m003" && echo "$out" | grep -q "from=opusD"; then
    pass "unread previews include m002 + m003"
else
    fail "previews missing — got: $(echo "$out" | head -5)"
fi

# ── Test 3: read message m001 NOT previewed ───────────────────────────────
echo ""
echo "Test 3: read message m001 NOT in preview"
if ! echo "$out" | grep -q "m001"; then
    pass "read message m001 correctly excluded"
else
    fail "read message m001 leaked into preview"
fi

# ── Test 4: CHUMP_OPUS_INBOX_HOOK=0 bypass quiet ───────────────────────────
echo ""
echo "Test 4: CHUMP_OPUS_INBOX_HOOK=0 disables hook output"
out=$(CHUMP_OPUS_INBOX_HOOK=0 run_hook || true)
if ! echo "$out" | grep -q "Opus inbox"; then
    pass "bypass quiet"
else
    fail "bypass leaked Opus inbox header"
fi

# ── Test 5: missing opus-inbox dir → silent skip ───────────────────────────
echo ""
echo "Test 5: missing opus-inbox dir → silent skip"
EMPTY=$(mktemp -d)
out=$(REPO_ROOT="$EMPTY" CHUMP_SESSION_ID="opusB" CHUMP_OPUS_INBOX_HOOK=1 \
    CHUMP_A2A_INBOX_INJECT=0 \
    bash scripts/coord/ambient-context-inject.sh SessionStart 2>/dev/null \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('hookSpecificOutput', {}).get('additionalContext', ''))
except Exception:
    pass
" || true)
rm -rf "$EMPTY"
if ! echo "$out" | grep -q "Opus inbox"; then
    pass "silent skip when dir missing"
else
    fail "header rendered despite missing inbox dir"
fi

# ── Test 6: read-only invariant — file sha unchanged after hook ────────────
echo ""
echo "Test 6: hook does NOT modify the inbox file"
SHA_BEFORE=$(shasum "$SANDBOX/.chump-locks/opus-inbox/all-opus.jsonl" | cut -d' ' -f1)
run_hook >/dev/null 2>&1 || true
SHA_AFTER=$(shasum "$SANDBOX/.chump-locks/opus-inbox/all-opus.jsonl" | cut -d' ' -f1)
if [[ "$SHA_BEFORE" == "$SHA_AFTER" ]]; then
    pass "read-only invariant holds (sha unchanged)"
else
    fail "hook mutated the inbox file"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
