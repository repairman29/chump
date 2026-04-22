#!/usr/bin/env bash
# INFRA-033: verify chump-mcp-coord responds on stdio (tools/list) without API keys.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ ! -x "$ROOT/target/debug/chump-mcp-coord" ]]; then
  cargo build -q -p chump-mcp-coord
fi

out="$(echo '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}' \
  | CHUMP_REPO="$ROOT" "$ROOT/target/debug/chump-mcp-coord")"

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
