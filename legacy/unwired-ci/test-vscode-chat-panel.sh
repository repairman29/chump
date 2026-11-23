#!/usr/bin/env bash
# test-vscode-chat-panel.sh — PRODUCT-057
# Validates the VS Code extension chat panel implementation.
# Runs static checks (no VS Code runtime required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXT="$REPO_ROOT/extensions/vscode-chump"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── 1: chatPanel.ts exists ───────────────────────────────────────────────────
[[ -f "$EXT/src/chatPanel.ts" ]] \
    || fail "chatPanel.ts not found at $EXT/src/chatPanel.ts"
pass "chatPanel.ts exists"

# ── 2: WebviewViewProvider implemented ──────────────────────────────────────
grep -q 'WebviewViewProvider' "$EXT/src/chatPanel.ts" \
    || fail "ChatPanel must implement vscode.WebviewViewProvider"
pass "ChatPanel implements WebviewViewProvider"

# ── 3: session/new call ──────────────────────────────────────────────────────
grep -q "session/new" "$EXT/src/chatPanel.ts" \
    || fail "chatPanel.ts must call session/new to create ACP session"
pass "chatPanel.ts calls session/new"

# ── 4: session/prompt call ───────────────────────────────────────────────────
grep -q "session/prompt" "$EXT/src/chatPanel.ts" \
    || fail "chatPanel.ts must call session/prompt to send user message"
pass "chatPanel.ts calls session/prompt"

# ── 5: SSE streaming via session/update notifications ────────────────────────
grep -q "session/update" "$EXT/src/chatPanel.ts" \
    || fail "chatPanel.ts must handle session/update notifications for streaming"
grep -q "agent_message_delta" "$EXT/src/chatPanel.ts" \
    || fail "chatPanel.ts must handle agent_message_delta update type"
pass "chatPanel.ts handles session/update streaming notifications"

# ── 6: markdown rendering present ────────────────────────────────────────────
grep -q "pre.*code\|code.*pre\|mdToHtml\|md(" "$EXT/src/chatPanel.ts" \
    || fail "chatPanel.ts must have markdown rendering (code blocks)"
pass "chatPanel.ts includes markdown rendering"

# ── 7: multi-turn: sessionId reused ─────────────────────────────────────────
grep -q 'sessionId\|session_id\|this\.sessionId' "$EXT/src/chatPanel.ts" \
    || fail "chatPanel.ts must persist sessionId for multi-turn conversation"
pass "chatPanel.ts persists sessionId for multi-turn"

# ── 8: extension.ts registers WebviewViewProvider ───────────────────────────
grep -q 'registerWebviewViewProvider' "$EXT/src/extension.ts" \
    || fail "extension.ts must register the WebviewViewProvider"
pass "extension.ts registers WebviewViewProvider"

# ── 9: package.json has chatView contribution ────────────────────────────────
grep -q 'chump.chatView' "$EXT/package.json" \
    || fail "package.json must declare chump.chatView view"
pass "package.json declares chump.chatView"

# ── 10: TypeScript compiles without errors ───────────────────────────────────
if [[ -x "$EXT/node_modules/.bin/tsc" ]]; then
    (cd "$EXT" && ./node_modules/.bin/tsc --noEmit 2>&1) \
        || fail "TypeScript compilation failed"
    pass "TypeScript compiles without errors"
else
    pass "TypeScript compiler not installed — skipping compile check (run 'npm install' in $EXT)"
fi

printf '\nAll chat-panel tests passed.\n'
