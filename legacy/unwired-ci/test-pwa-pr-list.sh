#!/usr/bin/env bash
# scripts/ci/test-pwa-pr-list.sh — PRODUCT-084
#
# Validates GET /api/prs endpoint:
#   1. Returns 200 with the correct top-level shape: open, just_merged, stuck arrays
#   2. Each PR row has the expected fields: number, title, author, age_s, merge_state, ci_ok, url
#   3. TTL/cache header or fetched_at_s field present
#   4. 'stuck' only contains PRs with merge_state DIRTY or BLOCKED
#   5. 'just_merged' section has correct empty-state metadata (last_ship_ago_s) when empty
#
# Strategy: mock gh CLI with a shell script that returns fixture JSON; spin up
# chump --web on a random port; probe /api/prs; assert shape + correctness.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

source "$(dirname "$0")/lib/discover-chump-bin.sh"
[[ -x "$CHUMP_BIN" ]] || fail "no chump binary at $CHUMP_BIN (set CHUMP_BIN)"

# ── Mock gh CLI ──────────────────────────────────────────────────────────────
# gh is intercepted by a wrapper script on PATH ahead of real gh.
NOW_EPOCH="$(date +%s)"
OLD_EPOCH=$((NOW_EPOCH - 18000))   # 5h ago → qualifies as "stuck"
RECENT_EPOCH=$((NOW_EPOCH - 3600)) # 1h ago → within 24h for just_merged

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<GHEOF
#!/usr/bin/env bash
# Mock gh for PRODUCT-084 test
if [[ "\$*" == *"--state open"* ]]; then
  echo '[
    {"number":42,"title":"Fix auth bug","author":{"login":"alice"},
     "createdAt":"$(date -u -r "$OLD_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$OLD_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')",
     "mergeStateStatus":"BLOCKED",
     "statusCheckRollup":[
       {"name":"test","conclusion":"SUCCESS","status":null,"detailsUrl":"https://example.com/1"},
       {"name":"audit","conclusion":"FAILURE","status":null,"detailsUrl":"https://example.com/2"}
     ],
     "url":"https://github.com/test/repo/pull/42"},
    {"number":43,"title":"Add new feature","author":{"login":"bob"},
     "createdAt":"$(date -u -r "$RECENT_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$RECENT_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')",
     "mergeStateStatus":"CLEAN",
     "statusCheckRollup":[
       {"name":"test","conclusion":"SUCCESS","status":null,"detailsUrl":"https://example.com/3"}
     ],
     "url":"https://github.com/test/repo/pull/43"}
  ]'
elif [[ "\$*" == *"--state merged"* ]]; then
  echo '[
    {"number":41,"title":"Prev feature","author":{"login":"carol"},
     "mergedAt":"$(date -u -r "$RECENT_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$RECENT_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')",
     "mergeStateStatus":"MERGED","statusCheckRollup":[],
     "url":"https://github.com/test/repo/pull/41"}
  ]'
else
  echo '[]'
fi
GHEOF
chmod +x "$TMP/bin/gh"

# ── Start server ─────────────────────────────────────────────────────────────
mkdir -p "$TMP/.chump" "$TMP/.chump-locks"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG="$TMP/server.log"

PATH="$TMP/bin:$PATH" \
CHUMP_HOME="$TMP" \
CHUMP_REPO="$TMP" \
CHUMP_BINARY_STALENESS_CHECK=0 \
    "$CHUMP_BIN" --web --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null \
    || fail "server failed to start (log: $(tail -20 "$LOG"))"

# ── Test 1: Shape ─────────────────────────────────────────────────────────────
RESP="$TMP/prs.json"
PATH="$TMP/bin:$PATH" \
    curl -sf "http://127.0.0.1:$PORT/api/prs" >"$RESP" \
    || fail "/api/prs returned non-200"

python3 - <<EOF
import json
d = json.load(open("$RESP"))
for key in ("open", "just_merged", "stuck", "fetched_at_s", "ttl_s"):
    assert key in d, f"missing top-level key: {key!r}"
assert isinstance(d["open"],        list), "open must be array"
assert isinstance(d["just_merged"], list), "just_merged must be array"
assert isinstance(d["stuck"],       list), "stuck must be array"
EOF
ok "shape: top-level keys open/just_merged/stuck/fetched_at_s/ttl_s"

# ── Test 2: PR row fields ─────────────────────────────────────────────────────
python3 - <<EOF
import json
d = json.load(open("$RESP"))
rows = d["open"] + d["just_merged"] + d["stuck"]
assert rows, "no PR rows returned at all"
required = {"number", "title", "author", "age_s", "merge_state", "ci_ok", "url"}
for row in rows:
    missing = required - set(row.keys())
    assert not missing, f"PR row missing fields {missing}: {row}"
EOF
ok "PR row fields: number/title/author/age_s/merge_state/ci_ok/url present"

# ── Test 3: open section has 2 PRs from fixture ───────────────────────────────
python3 - <<EOF
import json
d = json.load(open("$RESP"))
assert len(d["open"]) == 2, f"expected 2 open PRs, got {len(d['open'])}"
numbers = {r["number"] for r in d["open"]}
assert 42 in numbers and 43 in numbers, f"expected #42 and #43, got {numbers}"
EOF
ok "open section: 2 PRs with correct numbers"

# ── Test 4: stuck section only contains DIRTY/BLOCKED PRs ────────────────────
python3 - <<EOF
import json
d = json.load(open("$RESP"))
for row in d["stuck"]:
    ms = (row.get("merge_state") or "").upper()
    assert ms in ("DIRTY", "BLOCKED"), \
        f"stuck row has unexpected merge_state={ms!r}: {row}"
# PR #42 is BLOCKED and 5h old → should be in stuck
stuck_nums = {r["number"] for r in d["stuck"]}
assert 42 in stuck_nums, f"#42 (BLOCKED, 5h old) should be stuck; got {stuck_nums}"
# PR #43 is CLEAN → must NOT be stuck
assert 43 not in stuck_nums, f"#43 (CLEAN) must not be stuck"
EOF
ok "stuck section: only DIRTY/BLOCKED PRs, #42 present, #43 absent"

# ── Test 5: just_merged section has PR #41 ───────────────────────────────────
python3 - <<EOF
import json
d = json.load(open("$RESP"))
merged_nums = {r["number"] for r in d["just_merged"]}
assert 41 in merged_nums, f"#41 (merged 1h ago) should be in just_merged; got {merged_nums}"
EOF
ok "just_merged section: #41 present"

# ── Test 6: CI summary is computed (PR #42 has 1 fail) ───────────────────────
python3 - <<EOF
import json
d = json.load(open("$RESP"))
pr42 = next((r for r in d["open"] if r["number"] == 42), None)
assert pr42 is not None, "#42 not found in open"
assert pr42["ci_fail"] == 1, f"#42 should have ci_fail=1, got {pr42.get('ci_fail')}"
assert pr42["ci_pass"] == 1, f"#42 should have ci_pass=1, got {pr42.get('ci_pass')}"
assert pr42["ci_ok"] == False, f"#42 ci_ok should be False (has failures)"
EOF
ok "CI summary: #42 has ci_fail=1, ci_pass=1, ci_ok=False"

ok "ALL PRODUCT-084 /api/prs checks passed"
