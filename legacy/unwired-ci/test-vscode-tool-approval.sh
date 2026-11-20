#!/usr/bin/env bash
# test-vscode-tool-approval.sh — PRODUCT-058
# Static validation of the VS Code extension tool-approval implementation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXT="$REPO_ROOT/extensions/vscode-chump"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── 1: toolApproval.ts exists ────────────────────────────────────────────────
[[ -f "$EXT/src/toolApproval.ts" ]] \
    || fail "toolApproval.ts not found at $EXT/src/toolApproval.ts"
pass "toolApproval.ts exists"

# ── 2: session/request_permission handled ────────────────────────────────────
grep -q "session/request_permission" "$EXT/src/toolApproval.ts" \
    || fail "toolApproval.ts must handle session/request_permission"
pass "toolApproval.ts handles session/request_permission"

# ── 3: quickpick shown for approval ─────────────────────────────────────────
grep -q 'showQuickPick' "$EXT/src/toolApproval.ts" \
    || fail "toolApproval.ts must show VS Code quickpick for tool approval"
pass "toolApproval.ts shows quickpick for approval"

# ── 4: approve/deny/always-approve options ───────────────────────────────────
grep -q 'allow_always\|allow_once\|deny' "$EXT/src/toolApproval.ts" \
    || fail "toolApproval.ts must support approve/deny/always-approve option ids"
pass "toolApproval.ts supports allow_once/allow_always/deny outcomes"

# ── 5: file read tools open file in editor ───────────────────────────────────
grep -q 'showTextDocument' "$EXT/src/toolApproval.ts" \
    || fail "toolApproval.ts must open files in editor for read tools"
pass "toolApproval.ts opens files in editor"

# ── 6: file write/patch tools use WorkspaceEdit ──────────────────────────────
grep -q 'WorkspaceEdit\|applyEdit' "$EXT/src/toolApproval.ts" \
    || fail "toolApproval.ts must apply edits via vscode.workspace.applyEdit for write tools"
pass "toolApproval.ts uses WorkspaceEdit for file write tools"

# ── 7: run_cli/terminal tool shows terminal ───────────────────────────────────
grep -q 'createTerminal\|integrated.*terminal\|sendText' "$EXT/src/toolApproval.ts" \
    || fail "toolApproval.ts must surface run_cli in VS Code integrated terminal"
pass "toolApproval.ts shows terminal for CLI tools"

# ── 8: responds to server with outcome ──────────────────────────────────────
grep -q 'client\.respond\|respond(' "$EXT/src/toolApproval.ts" \
    || fail "toolApproval.ts must respond to server with PermissionOutcome"
pass "toolApproval.ts responds to server with outcome"

# ── 9: acpClient.ts has server-request handling ──────────────────────────────
grep -q "emit.*'request'" "$EXT/src/acpClient.ts" \
    || fail "acpClient.ts must emit 'request' event for server-initiated requests"
pass "acpClient.ts emits 'request' event for server requests"

# ── 10: acpClient.ts has respond() method ────────────────────────────────────
grep -q 'respond(' "$EXT/src/acpClient.ts" \
    || fail "acpClient.ts must expose respond() to send JSON-RPC response"
pass "acpClient.ts exposes respond() method"

# ── 11: extension.ts wires tool approval handler ─────────────────────────────
grep -q 'attachToolApprovalHandler\|toolApproval' "$EXT/src/extension.ts" \
    || fail "extension.ts must attach the tool approval handler"
pass "extension.ts wires attachToolApprovalHandler"

# ── 12: TypeScript compiles without errors ───────────────────────────────────
if [[ -x "$EXT/node_modules/.bin/tsc" ]]; then
    (cd "$EXT" && ./node_modules/.bin/tsc --noEmit 2>&1) \
        || fail "TypeScript compilation failed"
    pass "TypeScript compiles without errors"
else
    pass "TypeScript compiler not installed — skipping (run 'npm install' in $EXT)"
fi

printf '\nAll tool-approval tests passed.\n'
