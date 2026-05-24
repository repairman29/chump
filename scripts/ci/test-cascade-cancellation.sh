#!/usr/bin/env bash
# scripts/ci/test-cascade-cancellation.sh — INFRA-1870
#
# Smoke test: POST a synthetic workflow_run.completed (conclusion=cancelled)
# webhook event to the receiver and assert that kind=ci_cascade_cancelled is
# emitted to ambient.jsonl with the correct fields.
#
# Run:
#   bash scripts/ci/test-cascade-cancellation.sh
#
# Exit 0 = all assertions pass; exit 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static: receiver exists + parses ──────────────────────────────────────
[[ -f "$RECEIVER" ]] || fail "receiver missing: $RECEIVER"
python3 -c "import py_compile; py_compile.compile('$RECEIVER', doraise=True)" \
    || fail "receiver fails py_compile"
ok "receiver parses cleanly"

# ── 2. Event-registry-reserved.txt registers the new kind ────────────────────
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
[[ -f "$RESERVED" ]] || fail "event-registry-reserved.txt missing"
grep -q '^ci_cascade_cancelled' "$RESERVED" \
    || fail "ci_cascade_cancelled not in event-registry-reserved.txt"
ok "ci_cascade_cancelled registered in event-registry-reserved.txt"

# ── 3. End-to-end: spawn receiver, POST workflow_run.completed cancelled ──────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
CACHE_DB="$TMP/cache.db"
AMBIENT="$TMP/ambient.jsonl"
SECRET="testsecret_cascade"

CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="$SECRET" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    python3 "$RECEIVER" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for port to open (up to 4s)
for _ in $(seq 1 20); do
    if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.2
done
(echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null \
    || fail "receiver did not start in time (log: $(cat "$TMP/server.log"))"

# Construct synthetic workflow_run.completed payload with conclusion=cancelled.
# Matches the shape GH sends for a concurrency-group cancel-in-progress.
PAYLOAD=$(cat <<'EOF'
{
  "action": "completed",
  "workflow_run": {
    "id": 9998887776,
    "name": "CI",
    "head_sha": "deadbeef1234567890abcdef1234567890abcdef",
    "status": "completed",
    "conclusion": "cancelled",
    "run_started_at": "2026-05-24T00:00:00Z",
    "updated_at": "2026-05-24T00:01:00Z",
    "pull_requests": [
      {"number": 4242}
    ]
  }
}
EOF
)

SIG="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

RC=$(curl -s -o "$TMP/resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $SIG" \
    -H "X-GitHub-Event: workflow_run" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")

[[ "$RC" == "200" ]] \
    || fail "POST returned $RC (expected 200); body=$(cat "$TMP/resp.txt"); server=$(cat "$TMP/server.log")"
ok "POST workflow_run cancelled returned 200"

# Allow a brief moment for the async ambient write
sleep 0.3

# ── 4. Assert ci_cascade_cancelled emitted ────────────────────────────────────
grep -q '"kind":"ci_cascade_cancelled"' "$AMBIENT" \
    || fail "ci_cascade_cancelled not in ambient.jsonl: $(cat "$AMBIENT" 2>/dev/null)"
ok "kind=ci_cascade_cancelled emitted"

# ── 5. Assert correct fields ──────────────────────────────────────────────────
grep -q '"workflow_run_id":9998887776' "$AMBIENT" \
    || fail "workflow_run_id missing/wrong in ambient: $(cat "$AMBIENT")"
ok "workflow_run_id present"

grep -q '"pr_number":4242' "$AMBIENT" \
    || fail "pr_number missing/wrong in ambient: $(cat "$AMBIENT")"
ok "pr_number present"

grep -q '"predecessor_sha":"deadbeef' "$AMBIENT" \
    || fail "predecessor_sha missing/wrong in ambient: $(cat "$AMBIENT")"
ok "predecessor_sha present"

grep -q '"reason":"superseded"' "$AMBIENT" \
    || fail "reason missing/wrong in ambient: $(cat "$AMBIENT")"
ok "reason=superseded present"

# ── 6. Verify no emit for non-cancelled conclusion ────────────────────────────
> "$AMBIENT"
PAYLOAD_SUCCESS=$(cat <<'EOF'
{
  "action": "completed",
  "workflow_run": {
    "id": 9998887777,
    "name": "CI",
    "head_sha": "aaabbbccc1234567890abcdef1234567890abcdef",
    "status": "completed",
    "conclusion": "success",
    "run_started_at": "2026-05-24T00:02:00Z",
    "updated_at": "2026-05-24T00:03:00Z",
    "pull_requests": [{"number": 4243}]
  }
}
EOF
)
SIG2="sha256=$(printf '%s' "$PAYLOAD_SUCCESS" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"
RC2=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-Hub-Signature-256: $SIG2" \
    -H "X-GitHub-Event: workflow_run" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD_SUCCESS" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC2" == "200" ]] || fail "successful workflow_run POST returned $RC2"
sleep 0.3
if grep -q '"kind":"ci_cascade_cancelled"' "$AMBIENT" 2>/dev/null; then
    fail "ci_cascade_cancelled unexpectedly emitted for conclusion=success"
fi
ok "no ci_cascade_cancelled for conclusion=success"

echo
echo "All INFRA-1870 cascade-cancellation tests passed."
