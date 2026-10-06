#!/usr/bin/env bash
# INFRA-8079: Phase-3 chump-mcp-code tools — spawns the server over stdio, calls
# code.trait_impls, code.symbol_history and code.dead_code_scan, and asserts each
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

REPO="$T/repo"; mkdir -p "$REPO/src" "$REPO/web" "$REPO/docs/observability" "$REPO/.chump"
git -C "$REPO" init -q; git -C "$REPO" config user.email ci@chump.test; git -C "$REPO" config user.name CI
cat > "$REPO/src/lib.rs" <<'R'
pub trait Shape { fn area(&self) -> f64; }
pub struct Sq;
impl Shape for Sq { fn area(&self) -> f64 { 1.0 } }
impl<T> Shape for Vec<T> { fn area(&self) -> f64 { 0.0 } }
pub fn used_fn() -> i32 { 1 }
pub fn orphan_fn() -> i32 { 2 }
pub fn caller() -> i32 { used_fn() }
pub fn routes() { app.route("/api/live", get(h)).route("/api/dead/{id}", get(h)); }
R
printf 'class Impl(Base, Shape):\n    pass\n' > "$REPO/job.py"
printf "fetch('/api/live')\n" > "$REPO/web/app.js"
printf 'events:\n  - kind: emitted_kind\n  - kind: ghost_kind\n' > "$REPO/docs/observability/EVENT_REGISTRY.yaml"
printf 'echo emitted_kind\n' > "$REPO/emit.sh"
git -C "$REPO" add -A; git -C "$REPO" -c commit.gpgsign=false commit -q -m "add orphan_fn"
sed -i '/orphan_fn/d' "$REPO/src/lib.rs"; git -C "$REPO" -c commit.gpgsign=false commit -qam "remove orphan_fn"
git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m "unrelated"
export CHUMP_REPO="$REPO" CHUMP_CODE_INDEX_DB="$REPO/.chump/code_index.db"
"$BIN" index --all >/dev/null 2>&1

rpc() { printf '%s\n' "$1" | "$BIN" serve 2>/dev/null | head -1; }
check() { # <name> <json-request> <python assertions on d (the parsed result)>
    local out; out="$(rpc "$2")"
    if python3 -c "import sys,json; d=json.load(sys.stdin); assert 'error' not in d or d['error'] is None, d; d=d['result']; $3" <<<"$out" 2>"$T/err"; then
        ok "$1"
    else
        bad "$1: $out ($(tail -1 "$T/err"))"
    fi
}

check "tools/list advertises the three Phase-3 tools" \
    '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}' \
    "assert {t['name'] for t in d['tools']} >= {'code.trait_impls','code.symbol_history','code.dead_code_scan'}"

check "code.trait_impls: { trait, defined, count, truncated, impls[path,line,type,kind,language] }" \
    '{"jsonrpc":"2.0","method":"code.trait_impls","params":{"trait":"Shape"},"id":2}' \
    "assert d['trait']=='Shape' and d['defined'] is True and d['truncated'] is False and d['count']==3, d; assert all({'path','line','type','kind','language'} <= set(i) for i in d['impls']); assert sorted((i['type'],i['kind']) for i in d['impls'])==[('Impl','subclass'),('Sq','impl'),('Vec<T>','impl')], d"
check "code.trait_impls unknown trait: defined:false, empty impls" \
    '{"jsonrpc":"2.0","method":"code.trait_impls","params":{"trait":"Nope"},"id":3}' \
    "assert d['defined'] is False and d['count']==0 and d['impls']==[]"

check "code.symbol_history: { symbol, count, truncated, first_seen, last_changed, commits[sha,date,subject] } newest first" \
    '{"jsonrpc":"2.0","method":"code.symbol_history","params":{"symbol":"orphan_fn"},"id":4}' \
    "assert d['symbol']=='orphan_fn' and d['count']==2 and d['truncated'] is False, d; assert [c['subject'] for c in d['commits']]==['remove orphan_fn','add orphan_fn'], d; assert all({'sha','date','subject'} <= set(c) for c in d['commits']); assert len(d['first_seen'])==10 and len(d['last_changed'])==10"
check "code.symbol_history never-seen symbol: count 0, null dates" \
    '{"jsonrpc":"2.0","method":"code.symbol_history","params":{"symbol":"zzz_never"},"id":5}' \
    "assert d['count']==0 and d['commits']==[] and d['first_seen'] is None and d['last_changed'] is None"

check "code.dead_code_scan: symbol + file:line + reason for no_callers / no_emitters / registered_unused_route" \
    '{"jsonrpc":"2.0","method":"code.dead_code_scan","params":{},"id":6}' \
    "assert {'count','total','truncated','by_reason','findings'} <= set(d), d; f={(x['reason'],x['symbol']):x for x in d['findings']}; assert ('no_emitters','ghost_kind') in f and ('registered_unused_route','/api/dead/{id}') in f, d; assert ('no_callers','used_fn') not in f and ('no_emitters','emitted_kind') not in f and ('registered_unused_route','/api/live') not in f, d; assert all({'symbol','file','line','location','reason','kind'} <= set(x) and x['location']==x['file']+':'+str(x['line']) for x in d['findings']); assert f[('no_emitters','ghost_kind')]['location']=='docs/observability/EVENT_REGISTRY.yaml:3'"
check "code.dead_code_scan reasons filter + limit/truncated" \
    '{"jsonrpc":"2.0","method":"code.dead_code_scan","params":{"reasons":["no_emitters"],"limit":1},"id":7}' \
    "assert d['count']==1 and d['findings'][0]['reason']=='no_emitters' and set(d['by_reason'])=={'no_emitters'}, d"

out="$(rpc '{"jsonrpc":"2.0","method":"code.trait_impls","params":{},"id":8}')"
python3 -c "import sys,json; d=json.load(sys.stdin); assert d['error']['code']==-32603 and 'trait' in d['error']['message']" <<<"$out" \
    && ok "missing param -> JSON-RPC error" || bad "error shape: $out"

echo "=== mcp-code phase 3: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
