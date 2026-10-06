#!/usr/bin/env bash
# scripts/git-hooks/post-commit-code-index.sh — INFRA-8076 (INFRA-1583 slice)
#
# Incrementally refresh the tree-sitter code index (.chump/code_index.db) after a
# commit by re-indexing only the files that commit touched. Called from the
# post-commit hook; also runnable by hand. Best-effort by design: it never fails
# or slows a commit (the work runs in the background) and silently does nothing
# when the chump-mcp-code binary has not been built.
#
# Binary lookup: $CHUMP_MCP_CODE_BIN, then <cargo target dir>/{debug,release}, then PATH.
# Env: CHUMP_CODE_INDEX_DISABLE=1 turns it off; CHUMP_CODE_INDEX_SYNC=1 runs in the
#      foreground (tests).
set -uo pipefail

[[ "${CHUMP_CODE_INDEX_DISABLE:-0}" == "1" ]] && exit 0

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] || exit 0

BIN="${CHUMP_MCP_CODE_BIN:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
    TARGET="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
    for cand in "$TARGET/debug/chump-mcp-code" "$TARGET/release/chump-mcp-code" "$(command -v chump-mcp-code 2>/dev/null || true)"; do
        if [[ -n "$cand" && -x "$cand" ]]; then BIN="$cand"; break; fi
    done
fi
[[ -n "$BIN" && -x "$BIN" ]] || exit 0

if [[ "${CHUMP_CODE_INDEX_SYNC:-0}" == "1" ]]; then
    CHUMP_REPO="$REPO_ROOT" "$BIN" index --head >/dev/null 2>&1 || true
else
    ( CHUMP_REPO="$REPO_ROOT" "$BIN" index --head >/dev/null 2>&1 || true ) &
    disown 2>/dev/null || true
fi
exit 0
