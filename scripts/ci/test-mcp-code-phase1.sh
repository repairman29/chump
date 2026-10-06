#!/usr/bin/env bash
# INFRA-8077: Phase-1 chump-mcp-code tools — spawns the server over stdio, calls
# code.find_symbol, code.callers_of and code.gap_history, and asserts each
# response's documented shape. No network, no API keys.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if command -v cargo >/dev/null 2>&1; then
    TARGET_DIR="$(cargo metadata --no-deps --format-version 1 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("target_directory",""))' 2>/dev/null)"
fi
TARGET_DIR="${TARGET_DIR:-${CARGO_TARGET_DIR:-$ROOT/target}}"
BIN="${CHUMP_MCP_CODE_BIN:-$TARGET_DIR/debug/chump-mcp-code}"
if [[ ! -x "$BIN" ]] && command -v cargo >/dev/null 2>&1; then
    cargo build -q -p chump-mcp-code >/dev/null 2>&1 || true
fi
if [[ ! -x "$BIN" ]]; then
    echo "SKIP: chump-mcp-code not built at $BIN (cargo build -p chump-mcp-code)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

REPO="$T/repo"; mkdir -p "$REPO/src" "$REPO/.chump"
git -C "$REPO" init -q; git -C "$REPO" config user.email ci@chump.test; git -C "$REPO" config user.name CI
cat > "$REPO/src/lib.rs" <<'R'
pub fn compute_total() -> i32 { 1 }
pub fn report() -> i32 {
    compute_total() + 1
}
R
printf 'def run():\n    return compute_total()\n' > "$REPO/job.py"
git -C "$REPO" add -A; git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"
git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m "GHOST-9: removed feature (#77)"
python3 - "$REPO/.chump/state.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE gaps (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open',
                   closed_at INTEGER, closed_date TEXT NOT NULL DEFAULT '', closed_pr INTEGER);
INSERT INTO gaps (id, title, status) VALUES ('OPEN-1', 'still open', 'open');
INSERT INTO gaps (id, title, status, closed_at, closed_date, closed_pr) VALUES ('DONE-1', 'shipped', 'done', 1760000000, '2026-10-09', 4321);
""")
c.commit()
PY
export CHUMP_REPO="$REPO" CHUMP_CODE_INDEX_DB="$REPO/.chump/code_index.db" CHUMP_STATE_DB="$REPO/.chump/state.db"
"$BIN" index --all >/dev/null 2>&1

rpc() { printf '%s\n' "$1" | "$BIN" serve 2>/dev/null | head -1; }
check() { # <name> <json-request> <python assertions on d (the parsed result)>
    local out; out="$(rpc "$2")"
    if python3 -c "import sys,json; d=json.load(sys.stdin); assert 'error' not in d or d['error'] is None, d; d=d['result']; $3" <<<"$out" 2>/tmp/mcp-code-p1.err; then
        ok "$1"
    else
        bad "$1: $out ($(tail -1 /tmp/mcp-code-p1.err))"
    fi
}

# tools/list advertises the three Phase-1 tools
check "tools/list advertises code.find_symbol / callers_of / gap_history" \
    '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}' \
    "assert {t['name'] for t in d['tools']} >= {'code.find_symbol','code.callers_of','code.gap_history'}"

# code.find_symbol — hit and miss shapes
check "code.find_symbol hit: { symbol, exists:true, count, matches[path,name,kind,line,language] }" \
    '{"jsonrpc":"2.0","method":"code.find_symbol","params":{"name":"compute_total"},"id":2}' \
    "assert d['symbol']=='compute_total' and d['exists'] is True and d['count']==1; m=d['matches'][0]; assert {'path','name','kind','line','language'} <= set(m) and m['path']=='src/lib.rs' and m['language']=='rust'"
check "code.find_symbol miss: exists:false with an explicit empty matches list" \
    '{"jsonrpc":"2.0","method":"code.find_symbol","params":{"name":"nope_not_here"},"id":3}' \
    "assert d['exists'] is False and d['count']==0 and d['matches']==[]"

# code.callers_of
check "code.callers_of: { symbol, defined, count, truncated, callers[path,line,text,in_symbol] }" \
    '{"jsonrpc":"2.0","method":"code.callers_of","params":{"symbol":"compute_total"},"id":4}' \
    "assert d['defined'] is True and d['truncated'] is False and d['count']==2, d; assert all({'path','line','text','in_symbol'} <= set(c) for c in d['callers']); by={c['path']:c for c in d['callers']}; assert by['src/lib.rs']['in_symbol']=='report' and by['job.py']['in_symbol']=='run'"

# code.gap_history — all four statuses
check "code.gap_history open" \
    '{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"OPEN-1"},"id":5}' \
    "assert d['status']=='open' and d['shipped_pr'] is None and d['closed_date'] is None"
check "code.gap_history done: shipped_pr + closed_date" \
    '{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"DONE-1"},"id":6}' \
    "assert d['status']=='done' and d['shipped_pr']==4321 and d['closed_date']=='2026-10-09'"
check "code.gap_history reaped: no registry row but git history proves it existed (reaped_date + shipped_pr)" \
    '{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"GHOST-9"},"id":7}' \
    "assert d['status']=='reaped' and d['shipped_pr']==77 and len(d['reaped_date'])==10 and d['closed_date'] is None"
check "code.gap_history never_existed" \
    '{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"NOPE-404"},"id":8}' \
    "assert d['status']=='never_existed' and d['shipped_pr'] is None and d['reaped_date'] is None"

# bad input -> JSON-RPC error, not a crash
out="$(rpc '{"jsonrpc":"2.0","method":"code.find_symbol","params":{},"id":9}')"
python3 -c "import sys,json; d=json.load(sys.stdin); assert d['error']['code']==-32603 and 'name' in d['error']['message']" <<<"$out" \
    && ok "missing param -> JSON-RPC error" || bad "error shape: $out"

echo "=== mcp-code phase 1: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
