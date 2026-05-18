#!/usr/bin/env bash
# scripts/ci/test-api-inbox.sh — INFRA-1298

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
[ -x "$BIN" ] || { echo "[test] chump binary missing" >&2; exit 1; }

PORT="${TEST_PORT:-13849}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/.chump-locks/inbox"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m s

INBOX="$SANDBOX/.chump-locks/inbox/operator-test.jsonl"
cat > "$INBOX" <<EOF
{"event":"STUCK","session":"someone","ts":"2026-05-14T10:00:00Z","subject":"INFRA-1","reason":"old"}
{"event":"HANDOFF","session":"someone","ts":"2026-05-14T11:00:00Z","subject":"INFRA-2","to":"operator-test"}
{"event":"FEEDBACK","session":"someone","ts":"2026-05-14T12:00:00Z","kind":"proposal","subject":"sub"}
EOF

(cd "$SANDBOX" && CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" "$BIN" --web) > "$TMP/srv.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break
    sleep 0.5
done

# ── Test 1: GET returns 3 ───────────────────────────────────────────────
resp=$(curl -s "http://127.0.0.1:$PORT/api/inbox/operator-test")
n=$(echo "$resp" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('count',-1))")
[ "$n" = "3" ] || fail "expected count=3, got '$n', resp: $resp"
ok "GET /api/inbox/<sess> returns all 3 entries"

# ── Test 2: unread-count = 3 before ack ─────────────────────────────────
unread=$(curl -s "http://127.0.0.1:$PORT/api/inbox/operator-test/unread-count" | \
    python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('unread',-1))")
[ "$unread" = "3" ] || fail "expected unread=3 pre-ack, got '$unread'"
ok "unread-count pre-ack = 3"

# ── Test 3: POST ack with no body → marks all read ──────────────────────
curl -sf -X POST "http://127.0.0.1:$PORT/api/inbox/operator-test/ack" \
    -H 'content-type: application/json' -d '{}' >/dev/null
unread=$(curl -s "http://127.0.0.1:$PORT/api/inbox/operator-test/unread-count" | \
    python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('unread',-1))")
[ "$unread" = "0" ] || fail "expected unread=0 post-ack, got '$unread'"
ok "POST ack {} → marks all read; unread = 0"

# ── Test 4: ?unread=1 returns 0 after ack ───────────────────────────────
resp=$(curl -s "http://127.0.0.1:$PORT/api/inbox/operator-test?unread=1")
n=$(echo "$resp" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('count',-1))")
[ "$n" = "0" ] || fail "expected unread-only count=0 post-ack, got '$n'"
ok "?unread=1 honors cursor post-ack"

# ── Test 5: partial ack — ack only first ts, leaves 2 unread ────────────
curl -sf -X POST "http://127.0.0.1:$PORT/api/inbox/operator-test/ack" \
    -H 'content-type: application/json' \
    -d '{"up_to_ts":"2026-05-14T10:00:00Z"}' >/dev/null
unread=$(curl -s "http://127.0.0.1:$PORT/api/inbox/operator-test/unread-count" | \
    python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('unread',-1))")
[ "$unread" = "2" ] || fail "expected unread=2 after partial ack, got '$unread'"
ok "partial ack moves cursor; unread reflects remaining"

# ── Test 6: nonexistent session → empty, no 500 ─────────────────────────
resp=$(curl -s "http://127.0.0.1:$PORT/api/inbox/operator-never-existed")
echo "$resp" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['count']==0, d" \
    || fail "nonexistent session should return count=0: $resp"
ok "nonexistent session → empty messages, no error"

# ── Test 7: path traversal rejected ─────────────────────────────────────
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/inbox/..%2Fsomething")
# axum percent-decodes the path so .. ends up in the segment; my BAD_REQUEST guard fires.
[ "$code" = "400" ] || [ "$code" = "404" ] \
    || fail "path traversal should be rejected, got $code"
ok "path traversal attempt rejected"

echo
echo "All INFRA-1298 /api/inbox tests passed."
