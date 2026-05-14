#!/usr/bin/env bash
# scripts/ci/test-webhook-health-endpoint.sh — INFRA-1110
#
# Verifies GET /health on the webhook receiver returns the expected JSON.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$RECEIVER" ]] || fail "receiver missing"
grep -q 'INFRA-1110' "$RECEIVER" || fail "INFRA-1110 banner missing"
grep -q 'do_GET' "$RECEIVER" || fail "do_GET handler missing"
grep -q '/health' "$RECEIVER" || fail "/health path missing"
ok "static: INFRA-1110 banner + do_GET + /health path all present"

python3 -c "import py_compile; py_compile.compile('$RECEIVER', doraise=True)" \
    || fail "receiver fails py_compile"
ok "receiver py_compiles cleanly with new /health handler"

# Spin up receiver, hit /health, check JSON shape.
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="test123" \
    CHUMP_CACHE_DB="$TMP/cache.db" \
    CHUMP_AMBIENT_LOG="$TMP/amb.jsonl" \
    python3 "$RECEIVER" >"$TMP/srv.log" 2>&1 &
SERVER_PID=$!

# Wait for port open
for _ in $(seq 1 20); do
    if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.2
done

# Test 1: /health returns 200 + JSON
RESP=$(curl -s -o "$TMP/health.json" -w "%{http_code}" "http://127.0.0.1:$PORT/health")
[[ "$RESP" == "200" ]] || fail "/health returned $RESP (expected 200): $(cat "$TMP/health.json")"
python3 -c "
import json
d = json.load(open('$TMP/health.json'))
for f in ('status', 'pid', 'started_at', 'events_received_total', 'cache_db_path'):
    assert f in d, f'missing field: {f} in {d}'
assert d['status'] == 'ok', d
assert isinstance(d['pid'], int), d
assert d['events_received_total'] == 0, d
assert d['last_event_at'] is None, d
print('ok health JSON shape')
" || fail "/health JSON shape wrong"
ok "/health returns 200 + JSON with all required fields"

# Test 2: POST a valid webhook, then /health should reflect updated counter
SECRET="test123"
PAYLOAD='{"action":"opened","pull_request":{"number":42,"head":{"ref":"x","sha":"deadbeef"},"base":{"ref":"main","sha":"feedface"},"mergeable_state":"BEHIND","auto_merge":null,"draft":false,"merged_at":null,"title":"x","user":{"login":"u"},"updated_at":"2026-05-14T00:00:00Z"}}'
SIG="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"
curl -s -o /dev/null -w "%{http_code}\n" \
    -H "X-Hub-Signature-256: $SIG" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook" >/dev/null
sleep 0.2

curl -s "http://127.0.0.1:$PORT/health" >"$TMP/health2.json"
python3 -c "
import json
d = json.load(open('$TMP/health2.json'))
assert d['events_received_total'] == 1, d
assert d['last_event_at'] is not None, d
print('ok counters bumped')
" || fail "/health counters didn't bump after POST"
ok "/health counters reflect 1 event after POST"

# Test 3: unknown path returns 404
RESP=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/nope")
[[ "$RESP" == "404" ]] || fail "/nope expected 404, got $RESP"
ok "unknown GET paths return 404"

echo
echo "All INFRA-1110 health-endpoint tests passed."
