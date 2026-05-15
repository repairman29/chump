#!/usr/bin/env bash
# scripts/ci/test-api-stack-status-rate-limit.sh — INFRA-1337
#
# Verifies /api/stack-status .github_rate_limit field gets populated by the
# 60s in-process poller. Uses CHUMP_GH_RATE_LIMIT_OVERRIDE_JSON to stub the
# `gh api rate_limit` response without forking a real `gh`.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
[[ -x "$CHUMP_BIN" ]] || CHUMP_BIN="$(command -v chump || true)"
[[ -x "$CHUMP_BIN" ]] || fail "no chump binary found (set CHUMP_BIN)"

# ── Test 1: well-formed rate_limit JSON populates the field ───────────────
STUB='{"resources":{"core":{"limit":5000,"remaining":4123,"reset":1778900000},"graphql":{"limit":5000,"remaining":3876,"reset":1778900000}}}'
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG="$TMP/server1.log"
mkdir -p "$TMP/.chump-locks"
CHUMP_REPO="$TMP" \
CHUMP_BINARY_STALENESS_CHECK=0 \
CHUMP_GH_RATE_LIMIT_OVERRIDE_JSON="$STUB" \
    "$CHUMP_BIN" --web --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "server failed to start (log: $(cat "$LOG"))"

# First call kicks off the lazy poller. Wait ~1s for the poll to complete.
curl -sf "http://127.0.0.1:$PORT/api/stack-status" >/dev/null
sleep 1.5
R="$TMP/r1.json"
curl -sf "http://127.0.0.1:$PORT/api/stack-status" >"$R"

python3 - <<EOF
import json
d = json.load(open("$R"))
rl = d.get("github_rate_limit")
assert rl is not None, f"github_rate_limit field missing or null. response keys: {list(d.keys())}"
assert rl.get("graphql_remaining") == 3876, f"graphql_remaining wrong: {rl.get('graphql_remaining')}"
assert rl.get("graphql_limit") == 5000, f"graphql_limit wrong: {rl.get('graphql_limit')}"
assert rl.get("core_remaining") == 4123, f"core_remaining wrong: {rl.get('core_remaining')}"
assert rl.get("core_limit") == 5000, f"core_limit wrong: {rl.get('core_limit')}"
rai = rl.get("reset_at_iso")
assert rai and rai.endswith("Z") and "T" in rai, f"reset_at_iso not ISO-8601 UTC: {rai!r}"
assert d.get("github_rate_limit_error") is None, f"error field should be null on success, got {d.get('github_rate_limit_error')!r}"
EOF
[[ $? -eq 0 ]] || fail "github_rate_limit field assertions failed"
ok "well-formed stub → github_rate_limit populated with correct fields"

kill $SERVER_PID 2>/dev/null
wait 2>/dev/null
SERVER_PID=""

# ── Test 2: malformed stub → error field populated, payload null ──────────
BAD_STUB='not json at all'
PORT2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG2="$TMP/server2.log"
CHUMP_REPO="$TMP" \
CHUMP_BINARY_STALENESS_CHECK=0 \
CHUMP_GH_RATE_LIMIT_OVERRIDE_JSON="$BAD_STUB" \
    "$CHUMP_BIN" --web --port "$PORT2" >"$LOG2" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT2/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT2/api/stack-status" >/dev/null
sleep 1.5
R2="$TMP/r2.json"
curl -sf "http://127.0.0.1:$PORT2/api/stack-status" >"$R2"
python3 - <<EOF
import json
d = json.load(open("$R2"))
err = d.get("github_rate_limit_error")
assert err is not None and "parse" in err.lower(), f"error field should mention parse, got {err!r}"
EOF
[[ $? -eq 0 ]] || fail "malformed-stub error assertions failed"
ok "malformed stub → github_rate_limit_error populated"

kill $SERVER_PID 2>/dev/null

ok "ALL INFRA-1337 github_rate_limit field tests passed"
