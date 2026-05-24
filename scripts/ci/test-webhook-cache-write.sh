#!/usr/bin/env bash
# scripts/ci/test-webhook-cache-write.sh — INFRA-1873
#
# Smoke test for webhook_cache_write ambient event emission.
# Verifies that github-webhook-receiver.py emits kind=webhook_cache_write
# after each cache upsert so dashboards can distinguish webhook-driven
# cache freshness from REST-driven freshness.
#
# Cases:
#   1. Static: receiver parses cleanly + webhook_cache_write in event-registry-reserved.txt
#   2. pull_request webhook → pr_state row written + webhook_cache_write emitted (target=pr)
#   3. check_suite webhook  → check_runs row written + webhook_cache_write emitted (target=check_runs)
#   4. Duplicate pull_request POST is idempotent (one row, no double-emit)
#   5. Invalid signature → 401 + no webhook_cache_write emitted
#
# Smoke runs in <5s; covers signature-validated path (X-Hub-Signature-256) +
# invalid-signature reject. Payload shape verified per AC#2.
#
# Rust-First-Bypass: integration test for a Python webhook handler; bash is the
#   right shape for spawning the server, POSTing, and asserting on filesystem
#   state + ambient.jsonl.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

# ── 1. Static checks ──────────────────────────────────────────────────────────
[[ -f "$RECEIVER" ]] || fail "receiver missing: $RECEIVER"
python3 -c "import py_compile; py_compile.compile('$RECEIVER', doraise=True)" \
    || fail "receiver fails py_compile"
ok "receiver script parses cleanly"

grep -q 'webhook_cache_write' "$RESERVED" \
    || fail "webhook_cache_write not in event-registry-reserved.txt"
ok "webhook_cache_write registered in event-registry-reserved.txt"

grep -q '"kind": *"webhook_cache_write"' "$RECEIVER" \
    || grep -q "'kind': *'webhook_cache_write'" "$RECEIVER" \
    || grep -q '"kind".*webhook_cache_write' "$RECEIVER" \
    || python3 -c "
import ast, sys
src = open('$RECEIVER').read()
tree = ast.parse(src)
found = False
for node in ast.walk(tree):
    if isinstance(node, ast.Dict):
        for k, v in zip(node.keys, node.values):
            if (isinstance(k, ast.Constant) and k.value == 'kind'
                    and isinstance(v, ast.Constant) and v.value == 'webhook_cache_write'):
                found = True
if not found:
    sys.exit(1)
" || fail "no webhook_cache_write emit found in receiver (AST check)"
ok "webhook_cache_write emit site found in receiver"

# ── Spin up the receiver on an ephemeral port ─────────────────────────────────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
CACHE_DB="$TMP/cache.db"
AMBIENT="$TMP/ambient.jsonl"
SECRET="testsecret-infra-1873"

CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="$SECRET" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_LEASE_NO_AUTO_RELEASE=1 \
    CHUMP_NO_AUTO_PRUNE_WORKTREE=1 \
    python3 "$RECEIVER" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for port open (max 4s — must leave room for <5s total budget).
for _ in $(seq 1 40); do
    if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.1
done
(echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null \
    || fail "receiver did not start within 4s; log=$(cat "$TMP/server.log")"

# Helper: compute HMAC-SHA256 signature exactly as GitHub would.
sign_payload() {
    local body="$1"
    local hex
    hex=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')
    printf 'sha256=%s' "$hex"
}

# ── 2. pull_request webhook → pr_state row + webhook_cache_write(target=pr) ──
PR_PAYLOAD='{"action":"opened","pull_request":{"number":4242,"head":{"ref":"feat/test","sha":"aabbcc1234567890aabbcc1234567890aabbcc12"},"base":{"ref":"main","sha":"deadbeef1234"},"mergeable_state":"clean","auto_merge":null,"draft":false,"merged_at":null,"title":"INFRA-1873 cache-write smoke","user":{"login":"tester"},"updated_at":"2026-05-23T00:00:00Z"}}'

PR_SIG=$(sign_payload "$PR_PAYLOAD")
RC=$(curl -s -o "$TMP/pr_resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $PR_SIG" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PR_PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "pull_request webhook returned HTTP $RC: $(cat "$TMP/pr_resp.txt") log=$(cat "$TMP/server.log")"

# Assert pr_state row written.
ROW=$(sqlite3 "$CACHE_DB" "SELECT number FROM pr_state WHERE number=4242" 2>/dev/null)
[[ "$ROW" == "4242" ]] || fail "pr_state row not written for number=4242 (got: '$ROW')"
ok "pull_request: pr_state row written"

# Assert webhook_cache_write event with correct payload shape.
sleep 0.2
grep -q '"kind":"webhook_cache_write"' "$AMBIENT" \
    || fail "no webhook_cache_write in ambient.jsonl after pull_request POST; ambient=$(cat "$AMBIENT")"
grep -q '"target":"pr"' "$AMBIENT" \
    || fail "webhook_cache_write missing target=pr; ambient=$(cat "$AMBIENT")"
grep -q '"number":4242' "$AMBIENT" \
    || fail "webhook_cache_write missing number=4242; ambient=$(cat "$AMBIENT")"
grep -q '"head_sha":"aabbcc1234567890aabbcc1234567890aabbcc12"' "$AMBIENT" \
    || fail "webhook_cache_write missing head_sha; ambient=$(cat "$AMBIENT")"
grep -q '"action":"opened"' "$AMBIENT" \
    || fail "webhook_cache_write missing action=opened; ambient=$(cat "$AMBIENT")"
ok "pull_request: webhook_cache_write emitted with correct payload shape"

# ── 3. check_suite webhook → check_runs row + webhook_cache_write(target=check_runs) ──
CHECK_PAYLOAD='{"action":"completed","check_suite":{"id":9999,"head_sha":"aabbcc1234567890aabbcc1234567890aabbcc12","status":"completed","conclusion":"success","created_at":"2026-05-23T00:00:00Z","updated_at":"2026-05-23T00:01:00Z","app":{"slug":"github-actions"},"pull_requests":[{"number":4242}]}}'

CHECK_SIG=$(sign_payload "$CHECK_PAYLOAD")
RC=$(curl -s -o "$TMP/check_resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $CHECK_SIG" \
    -H "X-GitHub-Event: check_suite" \
    -H "Content-Type: application/json" \
    -d "$CHECK_PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "check_suite webhook returned HTTP $RC: $(cat "$TMP/check_resp.txt") log=$(cat "$TMP/server.log")"

# Assert check_runs row written.
sleep 0.2
CHECK_ROW=$(sqlite3 "$CACHE_DB" "SELECT head_sha, name FROM check_runs WHERE head_sha='aabbcc1234567890aabbcc1234567890aabbcc12'" 2>/dev/null)
[[ -n "$CHECK_ROW" ]] || fail "check_runs row not written for head_sha; got: '$CHECK_ROW'"
ok "check_suite: check_runs row written"

# Assert webhook_cache_write event with target=check_runs.
grep '"kind":"webhook_cache_write"' "$AMBIENT" | grep -q '"target":"check_runs"' \
    || fail "no webhook_cache_write with target=check_runs in ambient; ambient=$(cat "$AMBIENT")"
grep '"kind":"webhook_cache_write"' "$AMBIENT" | grep '"target":"check_runs"' | grep -q '"runs_count":1' \
    || fail "webhook_cache_write(check_runs) missing runs_count=1; ambient=$(cat "$AMBIENT")"
grep '"kind":"webhook_cache_write"' "$AMBIENT" | grep '"target":"check_runs"' | grep -q '"head_sha":"aabbcc' \
    || fail "webhook_cache_write(check_runs) missing head_sha; ambient=$(cat "$AMBIENT")"
ok "check_suite: webhook_cache_write emitted with target=check_runs + runs_count + head_sha"

# ── 4. Duplicate pull_request POST is idempotent (no double-emit) ─────────────
# Count events before second POST.
BEFORE=$(grep -c '"kind":"webhook_cache_write"' "$AMBIENT" 2>/dev/null || true)

RC=$(curl -s -o "$TMP/dup_resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $PR_SIG" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PR_PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "duplicate POST returned HTTP $RC"

sleep 0.2
AFTER=$(grep -c '"kind":"webhook_cache_write"' "$AMBIENT" 2>/dev/null || true)
# Each POST legitimately triggers one emit — idempotency means the DB row is
# upserted (not duplicated) but we do emit once per webhook delivery per the AC.
# Verify only +1 event was added (not 0 or 2+).
DELTA=$(( AFTER - BEFORE ))
[[ "$DELTA" -eq 1 ]] || fail "duplicate POST: expected exactly 1 new webhook_cache_write event, got delta=$DELTA (before=$BEFORE after=$AFTER)"

# Assert DB still has exactly one row for number=4242.
ROW_COUNT=$(sqlite3 "$CACHE_DB" "SELECT COUNT(*) FROM pr_state WHERE number=4242" 2>/dev/null)
[[ "$ROW_COUNT" == "1" ]] || fail "duplicate POST created $ROW_COUNT rows for number=4242, expected 1"
ok "duplicate POST: idempotent DB upsert + exactly one new ambient event"

# ── 5. Invalid signature → 401, no webhook_cache_write emitted ────────────────
BEFORE_INVALID=$(grep -c '"kind":"webhook_cache_write"' "$AMBIENT" 2>/dev/null || true)

RC=$(curl -s -o "$TMP/bad_resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: sha256=badhexdeadbeef" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PR_PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "401" ]] || fail "invalid-signature POST should return 401, got $RC"

sleep 0.2
AFTER_INVALID=$(grep -c '"kind":"webhook_cache_write"' "$AMBIENT" 2>/dev/null || true)
[[ "$AFTER_INVALID" -eq "$BEFORE_INVALID" ]] \
    || fail "invalid signature triggered a webhook_cache_write event (before=$BEFORE_INVALID after=$AFTER_INVALID)"
ok "invalid signature: 401 returned, no webhook_cache_write emitted"

echo ""
echo "All INFRA-1873 webhook-cache-write smoke tests passed."
