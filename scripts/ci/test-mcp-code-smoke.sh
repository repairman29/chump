#!/usr/bin/env bash
# INFRA-8076: smoke test for chump-mcp-code — the server starts and answers
# JSON-RPC on stdio, the index is populated, and the post-commit hook refreshes
# it incrementally. No network, no API keys.
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

REPO="$T/repo"; mkdir -p "$REPO/src"
git -C "$REPO" init -q; git -C "$REPO" config user.email ci@chump.test; git -C "$REPO" config user.name CI
cat > "$REPO/src/lib.rs" <<'R'
/// Greets.
pub fn greet_user() {}
pub struct Greeter;
R
printf '#!/usr/bin/env bash\nrun_all() { :; }\n' > "$REPO/run.sh"
printf 'def parse_it():\n    pass\n' > "$REPO/p.py"
git -C "$REPO" add -A; git -C "$REPO" -c commit.gpgsign=false commit -q -m init
export CHUMP_REPO="$REPO" CHUMP_CODE_INDEX_DB="$REPO/.chump/code_index.db"

rpc() { printf '%s\n' "$1" | "$BIN" serve 2>/dev/null | head -1; }
jq_py() { python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }

# 1. server answers tools/list
out="$(rpc '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}')"
jq_py "assert {t['name'] for t in d['result']['tools']} >= {'search_symbols','file_symbols','index_stats','reindex'}" <<<"$out" \
    && ok "server starts and lists its tools over stdio" || bad "tools/list: $out"

# 2. index the repo; the index is populated for rust, bash and python
"$BIN" index --all >/dev/null 2>&1
stats="$(rpc '{"jsonrpc":"2.0","method":"index_stats","params":{},"id":2}')"
jq_py "r=d['result']; assert r['files']==3 and all(r['by_language'][l]['symbols']>=1 for l in ('rust','bash','python')), r" <<<"$stats" \
    && ok "index populated (rust + bash + python) in a separate DB file" || bad "index_stats: $stats"
[[ -f "$CHUMP_CODE_INDEX_DB" ]] && ok ".chump/code_index.db created" || bad "index db missing"

# 3. search finds symbols
found="$(rpc '{"jsonrpc":"2.0","method":"search_symbols","params":{"query":"greet_user"},"id":3}')"
jq_py "assert d['result']['symbols'][0]['path']=='src/lib.rs'" <<<"$found" && ok "search_symbols finds a Rust fn" || bad "search: $found"

# 4. post-commit hook refreshes incrementally (only the touched file)
printf 'def parse_it():\n    pass\n\ndef fresh_after_commit():\n    pass\n' > "$REPO/p.py"
git -C "$REPO" add -A; git -C "$REPO" -c commit.gpgsign=false commit -q -m edit
CHUMP_CODE_INDEX_SYNC=1 CHUMP_MCP_CODE_BIN="$BIN" bash "$ROOT/scripts/git-hooks/post-commit-code-index.sh"
found="$(rpc '{"jsonrpc":"2.0","method":"search_symbols","params":{"query":"fresh_after_commit"},"id":4}')"
jq_py "assert d['result']['count']==1" <<<"$found" && ok "post-commit hook indexed the new symbol" || bad "hook did not refresh: $found"
git -C "$REPO" rm -q run.sh; git -C "$REPO" -c commit.gpgsign=false commit -q -m rm
CHUMP_CODE_INDEX_SYNC=1 CHUMP_MCP_CODE_BIN="$BIN" bash "$ROOT/scripts/git-hooks/post-commit-code-index.sh"
gone="$(rpc '{"jsonrpc":"2.0","method":"file_symbols","params":{"path":"run.sh"},"id":5}')"
jq_py "assert d['result']['count']==0" <<<"$gone" && ok "deleted file removed from the index by the hook" || bad "stale rows: $gone"

# 5. bad requests get JSON-RPC errors, not crashes
err="$(rpc '{"jsonrpc":"2.0","method":"search_symbols","params":{},"id":6}')"
jq_py "assert d['error']['code']==-32603 and 'query' in d['error']['message']" <<<"$err" && ok "missing param -> JSON-RPC error" || bad "error shape: $err"

echo "=== mcp-code smoke: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
