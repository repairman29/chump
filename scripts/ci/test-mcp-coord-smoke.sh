#!/usr/bin/env bash
# INFRA-033: verify chump-mcp-coord responds on stdio (tools/list) without API keys.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# INFRA-1602: shared helper resolves debug binaries + builds if missing.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ensure-debug-chump.sh"
MCP_COORD_BIN="$(ensure_debug_chump chump-mcp-coord)" || {
    echo "FAIL: chump-mcp-coord binary unavailable" >&2
    exit 1
}

out="$(echo '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}' \
  | CHUMP_REPO="$ROOT" "$MCP_COORD_BIN")"

echo "$out" | grep -q 'gap_preflight' || {
  echo "expected gap_preflight in tools/list response" >&2
  echo "$out" >&2
  exit 1
}
echo "$out" | grep -q 'musher_pick' || {
  echo "expected musher_pick in tools/list response" >&2
  exit 1
}
echo "ok: chump-mcp-coord tools/list smoke"
