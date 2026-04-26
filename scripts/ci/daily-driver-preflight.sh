#!/usr/bin/env bash
# Automate CLI/API checks from docs/daily-driver test plans (Weeks 1–3 subset).
# Does NOT: open GUI apps, write launchd plists to ~/Library, dump .env to docs, or run long heartbeats.
# Usage: from repo root: ./scripts/ci/daily-driver-preflight.sh
# CHUMP_PREFLIGHT_WEB_PORT (default 3847) — intentional E2E/preflight port; ./run-web.sh still defaults 3000 for daily dev.
# To see what URL automation would pick: ./scripts/setup/print-chump-web-base.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT="${CHUMP_PREFLIGHT_WEB_PORT:-3847}"
BASE="http://127.0.0.1:${PORT}"
FAIL=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; FAIL=1; }

echo "=== Day 1: Build & boot (CLI) ==="
cargo build --release --bin chump || fail "cargo build --release --bin chump"
[[ -x target/release/chump ]] || fail "target/release/chump missing"
pass "release binary"

brew services start ollama 2>/dev/null || true
ollama pull qwen2.5:14b 2>/dev/null || true
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:11434/v1/models || echo 000)
[[ "$code" == "200" ]] || fail "Ollama /v1/models HTTP $code"
pass "Ollama models"

export CHUMP_HOME="$ROOT"
export CHUMP_REPO="$ROOT"
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --check-config >/dev/null || fail "check-config"
pass "check-config"

echo "(Day 1 step 8: one --chump turn; may take 1–3 min)"
/usr/bin/time -p env CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --chump "Reply with exactly: PREFLIGHT_OK" 2>&1 | tee /tmp/chump-preflight-chump.txt | tail -5
grep -q PREFLIGHT_OK /tmp/chump-preflight-chump.txt || fail "--chump did not return PREFLIGHT_OK"
pass "--chump smoke"

echo ""
echo "=== Day 2: Web PWA (API) on port $PORT ==="
for pid in $(lsof -ti ":$PORT" 2>/dev/null || true); do
  kill "$pid" 2>/dev/null || true
done
sleep 1
echo "Starting web on $PORT (no CHUMP_WEB_TOKEN for curl-friendly API tests)…"
nohup env CHUMP_HOME="$ROOT" CHUMP_REPO="$ROOT" CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" \
  OPENAI_API_BASE=http://127.0.0.1:11434/v1 OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:14b \
  ./target/release/chump --web --port "$PORT" >>logs/chump-preflight-web.log 2>&1 &
for _ in $(seq 1 45); do
  curl -sf "$BASE/api/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "$BASE/api/health" >/dev/null || fail "health on $BASE"
h=$(curl -s "$BASE/api/health")
echo "$h" | grep -q chump-web || fail "health JSON missing chump-web"
echo "$h" | grep -q '"status":"ok"' || fail 'health JSON missing status ok'
pass "GET /api/health"

curl -sf "$BASE/api/sessions" >/dev/null || fail "GET /api/sessions"
python3 -c "import json,sys,urllib.request; u='$BASE/api/sessions'; r=urllib.request.urlopen(u); json.load(r)" || fail "sessions JSON parse"
pass "GET /api/sessions"

S1=$(curl -s -X POST "$BASE/api/sessions" -H 'Content-Type: application/json' -d '{}' | python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
S2=$(curl -s -X POST "$BASE/api/sessions" -H 'Content-Type: application/json' -d '{}' | python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
[[ -n "$S1" && -n "$S2" ]] || fail "session create"
curl -s "$BASE/api/sessions/$S1/messages" | python3 -c "import sys,json; json.load(sys.stdin)" || fail "messages JSON"
pass "sessions create + messages GET"

echo ""
echo "=== Day 3: ChumpMenu build ==="
./scripts/setup/build-chump-menu.sh >/dev/null || fail "build-chump-menu"
[[ -f ChumpMenu/ChumpMenu.app/Contents/MacOS/ChumpMenu ]] || fail "ChumpMenu.app binary"
pass "ChumpMenu.app built"

echo ""
echo "=== Day 3 step 24: allowlist (unit test) ==="
cargo test -p chump run_rm_rf_root_rejected_by_tight_allowlist -- --nocapture >/dev/null || fail "allowlist unit test"
pass "run_cli rm allowlist test"

echo ""
echo "=== Day 7: Tasks API ==="
curl -sf -X POST "$BASE/api/tasks" -H 'Content-Type: application/json' \
  -d '{"title":"Preflight task A","assignee":"chump","priority":1}' >/dev/null || fail "POST task A"
curl -sf -X POST "$BASE/api/tasks" -H 'Content-Type: application/json' \
  -d '{"title":"Preflight task B","assignee":"chump","priority":2}' >/dev/null || fail "POST task B"
curl -sf -X POST "$BASE/api/tasks" -H 'Content-Type: application/json' \
  -d '{"title":"Preflight task C","assignee":"chump","priority":3}' >/dev/null || fail "POST task C"
curl -sf "$BASE/api/tasks?status=pending" >/dev/null || fail "GET tasks pending"
pass "tasks API (3 created)"

echo ""
echo "=== Day 12: API edge (empty message) ==="
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/chat" \
  -H 'Content-Type: application/json' -d '{"message":"","session_id":"preflight-empty"}')
[[ "$code" == "400" || "$code" == "422" ]] || fail "empty chat expected 400/422 got $code"
pass "POST /api/chat empty body -> $code"

echo ""
echo "=== Day 12: API edge (oversized message > CHUMP_MAX_MESSAGE_LEN) ==="
big_code=$(env BASE="$BASE" python3 -c "
import json, os, urllib.error, urllib.request
base = os.environ['BASE']
msg = 'z' * 20000
req = urllib.request.Request(
    f'{base}/api/chat',
    data=json.dumps({'message': msg, 'session_id': 'preflight-oversize'}).encode(),
    headers={'Content-Type': 'application/json'},
    method='POST',
)
try:
    urllib.request.urlopen(req, timeout=30)
    print('999')
except urllib.error.HTTPError as e:
    print(e.code)
")
[[ "$big_code" == "400" ]] || fail "oversized chat expected 400 got $big_code"
pass "POST /api/chat oversize -> 400"

echo ""
echo "=== Day 12: API /task persistence + parallel stress ==="
SID=$(curl -s -X POST "$BASE/api/sessions" -H 'Content-Type: application/json' -d '{}' | python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
[[ -n "$SID" ]] || fail "session for /task persist"
TNAME="preflight-persist-$(date +%s)"
curl -sS -N --max-time 600 -X POST "$BASE/api/chat" \
  -H 'Content-Type: application/json' \
  -d "{\"message\":\"/task $TNAME\",\"session_id\":\"$SID\"}" >"/tmp/chump-preflight-task-persist.txt" || fail "chat /task persist curl"
grep -qi 'created task' /tmp/chump-preflight-task-persist.txt || fail "SSE missing Created task (persist)"
mc=$(curl -s "$BASE/api/sessions/$SID/messages" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[[ "${mc:-0}" -ge 2 ]] || fail "expected >=2 messages after /task got $mc"
pass "/task via API persists messages (count $mc)"

pok=0
for i in 1 2 3; do
  if curl -sS -N --max-time 600 -X POST "$BASE/api/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"message\":\"/task preflight-par-$i-$RANDOM\",\"session_id\":\"pf-par-$i-$RANDOM\"}" \
    | grep -qi 'created task'; then
    pok=$((pok + 1))
  fi
done
[[ "$pok" -eq 3 ]] || fail "parallel /task stress: expected 3 successes got $pok"
pass "parallel /task stress (3 concurrent)"

echo ""
echo "=== Day 4: inprocess-embed release build (required; slow) ==="
cargo build --release --bin chump --features inprocess-embed || fail "build inprocess-embed"
pass "cargo build --features inprocess-embed"

echo ""
echo "=== SQLite memory DB (if present) ==="
if [[ -f sessions/chump_memory.db ]]; then
  cnt=$(sqlite3 sessions/chump_memory.db "SELECT count(*) FROM chump_memory;" 2>/dev/null || echo 0)
  echo "chump_memory rows: $cnt"
  pass "sessions/chump_memory.db readable"
else
  echo "SKIP no sessions/chump_memory.db yet (normal on fresh clone)"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "=== PREFLIGHT SUMMARY: ALL CLI CHECKS PASSED ==="
else
  echo "=== PREFLIGHT SUMMARY: SOME CHECKS FAILED (see above) ==="
  exit 1
fi
