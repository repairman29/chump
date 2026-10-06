#!/usr/bin/env bash
# INFRA-8080: regression test for the "feature missing" misdiagnosis class
# (INFRA-1575 / INFRA-238). Replays the A2A scenario against a throwaway repo and
# asserts the tooling refutes the false "missing" claim:
#   - a plain registry lookup is ambiguous (same empty answer for a reaped gap and a
#     typo), which is how INFRA-1575 happened;
#   - code.gap_history returns status=done with a shipped_pr for a closed gap, and
#     status=reaped (with the shipped PR) for a gap whose row was reaped;
#   - code.find_symbol / code.callers_of confirm the feature is on the tree and wired in.
# No network, no API keys.
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

# ── The A2A scenario ─────────────────────────────────────────────────────────
# INFRA-1296 (A2A broadcast) is closed in the registry; INFRA-1297's row was
# reaped after it shipped, so the registry has nothing — only git remembers.
REPO="$T/repo"; mkdir -p "$REPO/scripts/coord" "$REPO/.chump"
git -C "$REPO" init -q; git -C "$REPO" config user.email ci@chump.test; git -C "$REPO" config user.name CI
cat > "$REPO/scripts/coord/broadcast.sh" <<'S'
#!/usr/bin/env bash
broadcast() { echo "sending: $1"; }
S
cat > "$REPO/scripts/coord/notify.sh" <<'S'
#!/usr/bin/env bash
notify_peers() {
  broadcast "hello peers"
}
S
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m "INFRA-1296: A2A broadcast surface (#1900)"
git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m "INFRA-1297: A2A inbox routing (#1960)"
python3 - "$REPO/.chump/state.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE gaps (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open',
                   closed_at INTEGER, closed_date TEXT NOT NULL DEFAULT '', closed_pr INTEGER);
INSERT INTO gaps (id, title, status, closed_at, closed_date, closed_pr)
  VALUES ('INFRA-1296', 'A2A broadcast', 'done', 1778900000, '2026-05-16', 1900);
""")
c.commit()
PY
export CHUMP_REPO="$REPO" CHUMP_CODE_INDEX_DB="$REPO/.chump/code_index.db" CHUMP_STATE_DB="$REPO/.chump/state.db"
"$BIN" index --all >/dev/null 2>&1

rpc() { printf '%s\n' "$1" | "$BIN" serve 2>/dev/null | head -1; }
assert() { # <name> <json-request> <python on d (the result)>
    local out; out="$(rpc "$2")"
    if python3 -c "import sys,json; d=json.load(sys.stdin); assert not d.get('error'), d; d=d['result']; $3" <<<"$out" 2>/dev/null; then ok "$1"; else bad "$1: $out"; fi
}

# 1. The naive check is the trap: a bare registry lookup is empty for BOTH a reaped
#    gap and a typo, so it cannot support a "missing" claim.
naive() { python3 - "$REPO/.chump/state.db" "$1" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM gaps WHERE id=?", (sys.argv[2],)).fetchone()[0])
PY
}
[[ "$(naive INFRA-1297)" == "0" && "$(naive INFRA-9999)" == "0" ]] \
    && ok "naive registry lookup is identical (empty) for a reaped gap and a typo — the INFRA-1575 trap" \
    || bad "naive lookup unexpectedly distinguishes them"

# 2. code.gap_history: the closed gap is done with a shipped_pr (the headline AC).
assert "code.gap_history INFRA-1296 -> status=done with shipped_pr" \
    '{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"INFRA-1296"},"id":1}' \
    "assert d['status']=='done' and d['shipped_pr']==1900 and d['closed_date']=='2026-05-16', d"

# 3. The reaped gap is NOT 'missing': reaped, with the PR that shipped it.
assert "code.gap_history INFRA-1297 -> status=reaped (existed, shipped), not never_existed" \
    '{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"INFRA-1297"},"id":2}' \
    "assert d['status']=='reaped' and d['shipped_pr']==1960 and d['reaped_date'], d"
assert "code.gap_history for a typo -> never_existed (the only status that supports 'missing')" \
    '{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"INFRA-9999"},"id":3}' \
    "assert d['status']=='never_existed' and d['shipped_pr'] is None, d"

# 4. The runtime surface exists and is wired in.
assert "code.find_symbol broadcast -> exists (the feature is on the tree)" \
    '{"jsonrpc":"2.0","method":"code.find_symbol","params":{"name":"broadcast"},"id":4}' \
    "assert d['exists'] and d['matches'][0]['path']=='scripts/coord/broadcast.sh', d"
assert "code.callers_of broadcast -> called from notify_peers (wired in, not dead code)" \
    '{"jsonrpc":"2.0","method":"code.callers_of","params":{"symbol":"broadcast"},"id":5}' \
    "assert d['defined'] and d['count']>=1 and any(c['in_symbol']=='notify_peers' for c in d['callers']), d"

# 5. The doc and the rule are in place (the rule is only load-bearing if agents can find it).
grep -q 'code.gap_history' "$ROOT/docs/process/CODE_INTELLIGENCE.md" 2>/dev/null \
    && ok "docs/process/CODE_INTELLIGENCE.md documents the tool surface" || bad "CODE_INTELLIGENCE.md missing or lacks code.gap_history"
grep -qi 'verify before a missing-claim' "$ROOT/docs/process/CODE_INTELLIGENCE.md" 2>/dev/null \
    && ok "the verify-before-missing-claim rule is documented" || bad "rule heading missing"
grep -q 'INFRA-238' "$ROOT/AGENTS.md" && grep -q 'INFRA-1575' "$ROOT/AGENTS.md" \
    && grep -qi 'Runtime verification before a missing-claim' "$ROOT/AGENTS.md" \
    && ok "AGENTS.md has the runtime-verification subsection citing INFRA-238 and INFRA-1575" || bad "AGENTS.md subsection missing"

echo "=== misdiagnosis prevention: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
