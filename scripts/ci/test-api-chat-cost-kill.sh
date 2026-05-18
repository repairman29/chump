#!/usr/bin/env bash
# scripts/ci/test-api-chat-cost-kill.sh — INFRA-1335
#
# Verifies POST /api/chat cost kill-gate:
#   1. Normal sessions (no threshold) → 200 SSE stream opens
#   2. Session cost exceeds [cost] kill threshold → 402 + correct JSON body
#   3. 402 body contains error, session_cost_usd, threshold_usd fields
#   4. Session under threshold → still 200

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

source "$(dirname "$0")/lib/discover-chump-bin.sh"
[[ -x "$CHUMP_BIN" ]] || fail "no chump binary at $CHUMP_BIN (set CHUMP_BIN)"

# Synthetic CHUMP_HOME with [cost] kill = 1.0
mkdir -p "$TMP/.chump" "$TMP/.chump-locks"
cat > "$TMP/.chump/config.toml" <<'EOF'
[cost]
kill = 1.0
EOF

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG="$TMP/server.log"

# ── Test 1 & 4: session cost BELOW threshold → 200 SSE ─────────────────────
# CHUMP_SESSION_COST_USD=0.5 < kill=1.0 → should open SSE stream (status 200)
CHUMP_HOME="$TMP" \
CHUMP_REPO="$TMP" \
CHUMP_SESSION_COST_USD="0.5" \
CHUMP_BINARY_STALENESS_CHECK=0 \
OPENAI_API_KEY="test-key-no-call" \
    "$CHUMP_BIN" --web --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null \
    || fail "server failed to start (log: $(cat "$LOG"))"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d '{"message":"hi","session_id":"test-session"}' \
    "http://127.0.0.1:$PORT/api/chat")
# SSE opens: 200. (Provider call itself may fail with no real model, but the
# kill-gate must not fire — we verify the gate returns 200, not 402.)
[[ "$STATUS" == "200" ]] \
    || fail "expected 200 under threshold, got $STATUS"
ok "under threshold: status 200"

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# ── Test 2 & 3: session cost EXCEEDS threshold → 402 + JSON body ────────────
# CHUMP_SESSION_COST_USD=5.0 > kill=1.0 → 402
PORT2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG2="$TMP/server2.log"

CHUMP_HOME="$TMP" \
CHUMP_REPO="$TMP" \
CHUMP_SESSION_COST_USD="5.0" \
CHUMP_BINARY_STALENESS_CHECK=0 \
OPENAI_API_KEY="test-key-no-call" \
    "$CHUMP_BIN" --web --port "$PORT2" >"$LOG2" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT2/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT2/api/health" >/dev/null \
    || fail "server2 failed to start (log: $(cat "$LOG2"))"

RESP="$TMP/resp.json"
STATUS=$(curl -s -o "$RESP" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d '{"message":"hi","session_id":"test-session"}' \
    "http://127.0.0.1:$PORT2/api/chat")

[[ "$STATUS" == "402" ]] \
    || fail "expected 402 over threshold, got $STATUS (body: $(cat "$RESP"))"
ok "over threshold: status 402"

python3 - <<EOF
import json, sys
body = json.load(open("$RESP"))
assert body.get("error") == "session_cost_exceeded", \
    f"wrong error field: {body!r}"
cost = body.get("session_cost_usd")
thresh = body.get("threshold_usd")
assert cost is not None, f"session_cost_usd missing: {body!r}"
assert thresh is not None, f"threshold_usd missing: {body!r}"
assert float(cost) > float(thresh), \
    f"session_cost_usd({cost}) should be > threshold_usd({thresh})"
EOF
ok "402 body: error=session_cost_exceeded, session_cost_usd > threshold_usd"

# ── Test 4: no [cost] kill in config → no gate, 200 ────────────────────────
TMP2="$(mktemp -d)"
trap 'rm -rf "$TMP2"' EXIT
mkdir -p "$TMP2/.chump" "$TMP2/.chump-locks"
# Deliberately no [cost] kill in config
cat > "$TMP2/.chump/config.toml" <<'EOF'
[api]
EOF

PORT3=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG3="$TMP/server3.log"
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

CHUMP_HOME="$TMP2" \
CHUMP_REPO="$TMP2" \
CHUMP_SESSION_COST_USD="999.0" \
CHUMP_BINARY_STALENESS_CHECK=0 \
OPENAI_API_KEY="test-key-no-call" \
    "$CHUMP_BIN" --web --port "$PORT3" >"$LOG3" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT3/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT3/api/health" >/dev/null \
    || fail "server3 failed to start (log: $(cat "$LOG3"))"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d '{"message":"hi","session_id":"test-session"}' \
    "http://127.0.0.1:$PORT3/api/chat")
[[ "$STATUS" == "200" ]] \
    || fail "expected 200 with no kill config even at high cost, got $STATUS"
ok "no kill config: high-cost session still returns 200 (gate disabled)"

ok "ALL INFRA-1335 /api/chat cost kill-gate checks passed"
