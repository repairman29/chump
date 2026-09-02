#!/usr/bin/env bash
# almanac-drift-extract.sh — CREDIBLE-569 (CREDIBLE-222 slice)
#
# Pulls the latest CONFIG-organ DRIFT flags for a repo from the almanac
# service (the almanac-mcp JSON-RPC server, one-shot over stdio) and stashes
# the raw payload in a temp file for offline triage. Read-only: does not
# mutate any canonical state.
#
# Usage:
#   scripts/dev/almanac-drift-extract.sh [repo] [--out FILE]
#
# repo defaults to "chump". Prints the output file path and the number of
# drift flags retrieved; exits non-zero on any failure.
set -euo pipefail

REPO="chump"
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)
            OUT="$2"
            shift 2
            ;;
        *)
            REPO="$1"
            shift
            ;;
    esac
done

BIN="${CHUMP_ALMANAC_MCP_BIN:-$HOME/Projects/almanac/target/release/almanac-mcp}"
if [[ ! -x "$BIN" ]]; then
    echo "almanac-drift-extract: almanac-mcp binary not found or not executable at $BIN" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "almanac-drift-extract: jq is required" >&2
    exit 1
fi

if [[ -z "$OUT" ]]; then
    OUT="$(mktemp -t "chump-drift-flags-${REPO}-XXXXXX.json")"
fi

REQUEST=$(jq -nc --arg repo "$REPO" \
    '{jsonrpc:"2.0", id:1, method:"tools/call", params:{name:"almanac_comprehend", arguments:{repo:$repo, organ:"config"}}}')

RESPONSE="$(echo "$REQUEST" | timeout 30 "$BIN" 2>/dev/null | tail -n1 || true)"

if [[ -z "$RESPONSE" ]]; then
    echo "almanac-drift-extract: empty response from almanac-mcp (repo='$REPO')" >&2
    exit 1
fi

if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    echo "almanac-drift-extract: almanac-mcp returned an error: $(echo "$RESPONSE" | jq -c '.error')" >&2
    exit 1
fi

PAYLOAD="$(echo "$RESPONSE" | jq -r '.result.content[0].text // empty')"
if [[ -z "$PAYLOAD" ]]; then
    echo "almanac-drift-extract: no content text in mcp response" >&2
    exit 1
fi

echo "$PAYLOAD" > "$OUT"

COUNT="$(echo "$PAYLOAD" | jq -r '.organs.config.drift_count // 0')"

echo "almanac-drift-extract: retrieved $COUNT drift flag(s) for repo '$REPO' -> $OUT"
