#!/usr/bin/env bash
# ambient-session-end.sh — FLEET-019
#
# Wired into Claude Code Stop hook by FLEET-022. Emits one `session_end` event
# to .chump-locks/ambient.jsonl so siblings see this session has stopped, and
# (best-effort) releases this session's lease so other agents aren't blocked
# waiting for an expired-but-still-on-disk lease.
#
# Lease release uses `chump --release` if the binary supports it; otherwise
# falls back to deleting our own .chump-locks/<session>.json. The TTL on
# leases means stale ones expire on their own, so this is opportunistic.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"

SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]] && [[ -f "$REPO_ROOT/.chump-locks/.wt-session-id" ]]; then
    SESSION_ID="$(cat "$REPO_ROOT/.chump-locks/.wt-session-id" 2>/dev/null || true)"
fi

# Best-effort: emit session_end event
if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
    CHUMP_SESSION_ID="$SESSION_ID" \
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" session_end 2>/dev/null || true
fi

# Best-effort: release our lease
if [[ -n "$SESSION_ID" ]] && [[ -f "$LOCK_DIR/$SESSION_ID.json" ]]; then
    if command -v chump &>/dev/null && chump --help 2>&1 | grep -q -- '--release'; then
        chump --release 2>/dev/null || rm -f "$LOCK_DIR/$SESSION_ID.json"
    else
        rm -f "$LOCK_DIR/$SESSION_ID.json"
    fi
fi

exit 0
