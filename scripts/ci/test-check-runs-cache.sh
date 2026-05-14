#!/usr/bin/env bash
# scripts/ci/test-check-runs-cache.sh — INFRA-1107
#
# Verifies the check_runs cache:
#   1. Receiver creates check_runs table + index
#   2. check_suite webhook upserts rows for the head SHA
#   3. workflow_run webhook upserts too
#   4. cache_lookup_checks <sha> returns the cached rows

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"
CACHE_LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Static checks
grep -q 'INFRA-1107' "$RECEIVER" || fail "INFRA-1107 banner missing from receiver"
grep -q 'CREATE TABLE IF NOT EXISTS check_runs' "$RECEIVER" \
    || fail "check_runs schema missing"
grep -q '_upsert_check_runs' "$RECEIVER" || fail "_upsert_check_runs missing"
ok "static: receiver has check_runs schema + upsert helper"

grep -q 'cache_lookup_checks' "$CACHE_LIB" || fail "cache_lookup_checks missing from lib"
ok "static: github_cache.sh has cache_lookup_checks helper"

# Live functional test: spin up receiver, post check_suite webhook, verify cache row.
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
CACHE_DB="$TMP/cache.db"
AMB="$TMP/ambient.jsonl"
SECRET="testsecret"

CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="$SECRET" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMB" \
    python3 "$RECEIVER" >"$TMP/srv.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 20); do
    if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.2
done

# check_suite webhook payload
PAYLOAD='{"action":"completed","check_suite":{"head_sha":"abc123def","status":"completed","conclusion":"success","created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:05:00Z","app":{"slug":"github-actions"},"pull_requests":[]}}'
SIG="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"
RC=$(curl -s -o "$TMP/r.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $SIG" \
    -H "X-GitHub-Event: check_suite" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "check_suite webhook returned $RC"
sleep 0.3

# Verify check_runs row inserted
ROW=$(sqlite3 "$CACHE_DB" "SELECT head_sha, name, conclusion FROM check_runs WHERE head_sha='abc123def'")
[[ "$ROW" == "abc123def|github-actions|success" ]] || fail "check_runs row wrong: $ROW"
ok "check_suite webhook upserts check_runs row"

# cache_lookup_checks returns the rows
RESULT=$(CHUMP_CACHE_DB="$CACHE_DB" bash -c "source '$CACHE_LIB' && cache_lookup_checks abc123def")
echo "$RESULT" | grep -q "github-actions" || fail "cache_lookup_checks didn't return row: $RESULT"
echo "$RESULT" | grep -q "success" || fail "conclusion missing: $RESULT"
ok "cache_lookup_checks returns rows for head SHA"

# workflow_run webhook
WPAYLOAD='{"action":"completed","workflow_run":{"head_sha":"abc123def","name":"CI / cargo-test","status":"completed","conclusion":"failure","run_started_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:10:00Z","pull_requests":[]}}'
WSIG="sha256=$(printf '%s' "$WPAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"
RC=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-Hub-Signature-256: $WSIG" \
    -H "X-GitHub-Event: workflow_run" \
    -H "Content-Type: application/json" \
    -d "$WPAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "workflow_run webhook returned $RC"
sleep 0.3
ROW2=$(sqlite3 "$CACHE_DB" "SELECT name, conclusion FROM check_runs WHERE head_sha='abc123def' AND name='CI / cargo-test'")
[[ "$ROW2" == "CI / cargo-test|failure" ]] || fail "workflow_run row wrong: $ROW2"
ok "workflow_run webhook upserts check_runs row with its name"

# Should now have 2 rows for the same SHA
COUNT=$(sqlite3 "$CACHE_DB" "SELECT COUNT(*) FROM check_runs WHERE head_sha='abc123def'")
[[ "$COUNT" == "2" ]] || fail "expected 2 rows for the SHA, got $COUNT"
ok "two check_runs rows coexist for the same head SHA (different names)"

echo
echo "All INFRA-1107 check-runs-cache tests passed."
