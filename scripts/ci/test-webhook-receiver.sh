#!/usr/bin/env bash
# scripts/ci/test-webhook-receiver.sh — INFRA-1081
#
# Functional + static tests:
#   1. Receiver script exists + python parses
#   2. cache lib + reconcile script + queue-driver migration in place
#   3. EVENT_REGISTRY registers all 4 new kinds
#   4. End-to-end: spawn receiver, POST a synthetic pull_request webhook with
#      valid HMAC, assert pr_state row inserted + ambient event emitted
#   5. POST with wrong HMAC → 401 + webhook_event_rejected ambient
#   6. cache_query_behind_prs returns numbers when DB has BEHIND rows

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"
CACHE_LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
RECONCILE="$REPO_ROOT/scripts/ops/github-cache-reconcile.sh"
QUEUE_DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static existence + syntax ────────────────────────────────────────────
[[ -f "$RECEIVER" ]] || fail "receiver missing"
python3 -c "import py_compile; py_compile.compile('$RECEIVER', doraise=True)" \
    || fail "receiver fails py_compile"
ok "receiver script parses cleanly"

[[ -f "$CACHE_LIB" ]] || fail "cache lib missing"
bash -n "$CACHE_LIB" || fail "cache lib has syntax error"
ok "github_cache.sh parses cleanly"

[[ -x "$RECONCILE" ]] || fail "reconcile script missing or not executable"
bash -n "$RECONCILE" || fail "reconcile script has syntax error"
ok "github-cache-reconcile.sh parses cleanly"

# ── 2. queue-driver migration ──────────────────────────────────────────────
grep -q 'lib/github_cache.sh' "$QUEUE_DRIVER" \
    || fail "queue-driver doesn't source lib/github_cache.sh"
grep -q 'cache_query_behind_prs' "$QUEUE_DRIVER" \
    || fail "queue-driver doesn't call cache_query_behind_prs"
ok "queue-driver migrated to cache-first lookup"

# ── 3. EVENT_REGISTRY ──────────────────────────────────────────────────────
for k in webhook_event_received webhook_event_rejected cache_drift cache_miss; do
    grep -q "kind: $k" "$REG" || fail "EVENT_REGISTRY missing kind=$k"
done
ok "EVENT_REGISTRY registers all 4 new kinds"

# ── 4. End-to-end: receiver + HMAC + DB write + ambient emit ───────────────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
CACHE_DB="$TMP/cache.db"
AMBIENT="$TMP/ambient.jsonl"
SECRET="testsecret123"

CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="$SECRET" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    python3 "$RECEIVER" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for port open
for _ in $(seq 1 20); do
    if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.2
done

# Construct synthetic pull_request webhook payload
PAYLOAD='{"action":"opened","pull_request":{"number":1234,"head":{"ref":"feature","sha":"abc1234567"},"base":{"ref":"main","sha":"def1234567"},"mergeable_state":"BEHIND","auto_merge":{"merge_method":"squash"},"draft":false,"merged_at":null,"title":"Test PR","user":{"login":"tester"},"updated_at":"2026-05-14T00:00:00Z"}}'
SIG="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

RC=$(curl -s -o "$TMP/resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $SIG" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "valid webhook returned $RC: $(cat "$TMP/resp.txt") server=$(cat "$TMP/server.log")"

# Verify DB row
ROW=$(sqlite3 "$CACHE_DB" "SELECT number, mergeable_state, auto_merge_enabled FROM pr_state WHERE number=1234" 2>/dev/null)
[[ "$ROW" == "1234|BEHIND|1" ]] || fail "pr_state row wrong: $ROW"

# Verify ambient event
sleep 0.3
grep -q '"kind":"webhook_event_received"' "$AMBIENT" \
    || fail "no webhook_event_received in ambient: $(cat "$AMBIENT" 2>/dev/null)"
grep -q '"pr_number":1234' "$AMBIENT" || fail "ambient missing pr_number=1234"
ok "valid HMAC: 200, pr_state row inserted, webhook_event_received emitted"

# ── 5. Wrong HMAC ──────────────────────────────────────────────────────────
> "$AMBIENT"
RC=$(curl -s -o "$TMP/resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: sha256=wronghexhere" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "401" ]] || fail "wrong-HMAC should return 401, got $RC"
sleep 0.3
grep -q '"kind":"webhook_event_rejected"' "$AMBIENT" \
    || fail "no webhook_event_rejected in ambient: $(cat "$AMBIENT")"
ok "invalid HMAC: 401 + webhook_event_rejected emitted"

# ── 6. cache_query_behind_prs ─────────────────────────────────────────────
# Use the DB we just wrote — should report 1234 (BEHIND + auto_merge_enabled=1)
RESULT=$(CHUMP_CACHE_DB="$CACHE_DB" bash -c "
    source '$CACHE_LIB'
    cache_query_behind_prs
")
[[ "$RESULT" == "1234" ]] || fail "cache_query_behind_prs returned '$RESULT', expected '1234'"
ok "cache_query_behind_prs returns BEHIND auto-merge-armed PR numbers"

echo
echo "All INFRA-1081 webhook-receiver tests passed."
