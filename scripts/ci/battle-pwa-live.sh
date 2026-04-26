#!/usr/bin/env bash
# battle-pwa-live.sh — End-to-end battle test exercising the full Chump PWA
# chat pipeline: SSE streaming, tool calls, narration detection, task CRUD.
#
# Requires: a running Chump web server + inference backend (Ollama/MLX/vLLM).
#   CHUMP_WEB_PORT=3001 ./scripts/ci/battle-pwa-live.sh
#
# What it tests:
#   1. Greeting (should NOT hallucinate actions)
#   2. Math question (fast path, no tools needed)
#   3. Task creation (MUST call task tool)
#   4. Task listing (MUST call task tool)
#   5. File creation request (MUST call write_file)
#   6. Multi-turn: ask status, then close task
#
# Scoring: each scenario is PASS/FAIL/WARN. Final score printed.
# Logs: logs/battle-pwa-live.log

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/battle-pwa-live.log"

HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
PORT="${CHUMP_WEB_PORT:-3001}"
BASE="http://${HOST}:${PORT}"

AUTH=()
if [[ -n "${CHUMP_WEB_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${CHUMP_WEB_TOKEN}")
fi

TIMEOUT="${CHUMP_BATTLE_TIMEOUT:-60}"
PASSES=0
FAILS=0
WARNS=0

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }
pass() { log "PASS: $*"; PASSES=$((PASSES + 1)); }
fail() { log "FAIL: $*"; FAILS=$((FAILS + 1)); }
warn() { log "WARN: $*"; WARNS=$((WARNS + 1)); }

# Send a chat message and collect the full SSE response.
# Returns the assistant's final text in $REPLY_TEXT and raw SSE in $RAW_SSE.
send_chat() {
  local session_id="$1" message="$2"
  local tmpfile
  tmpfile=$(mktemp)

  local payload
  payload=$(python3 -c "import json; print(json.dumps({'message': '$message', 'session_id': '$session_id'}))")

  # Stream SSE, collect all data lines
  curl -sS -N --max-time "$TIMEOUT" \
    -X POST "${BASE}/api/chat" \
    -H "Content-Type: application/json" \
    "${AUTH[@]+"${AUTH[@]}"}" \
    -d "$payload" \
    > "$tmpfile" 2>/dev/null || true

  RAW_SSE=$(cat "$tmpfile")

  # Extract assistant text from SSE data lines
  # Chump SSE format: text_complete has full text, turn_complete has metadata,
  # tool_call_start has tool name, tool_result has output.
  REPLY_TEXT=$(python3 -c "
import sys, json
full_text = ''
tool_calls = []
for line in open('$tmpfile'):
    line = line.strip()
    if not line.startswith('data: '): continue
    raw = line[6:]
    if raw == '[DONE]': continue
    try:
        d = json.loads(raw)
        t = d.get('type', '')
        if t == 'text_complete':
            full_text = d.get('text', '')
        elif t == 'turn_complete':
            if not full_text:
                full_text = d.get('full_text', '')
            tc = d.get('tool_calls_count', 0)
            mc = d.get('model_calls_count', 0)
        elif t in ('tool_call_start', 'tool_call'):
            tn = d.get('tool_name', d.get('name', '?'))
            if tn and tn != '?':
                tool_calls.append(tn)
    except: pass
print('TOOLS:' + ','.join(tool_calls) if tool_calls else 'TOOLS:none')
print('TEXT:' + full_text[:500])
" 2>/dev/null || echo "TOOLS:none
TEXT:(parse error)")

  HAS_TOOL_CALLS=false
  TOOL_NAMES=""
  if echo "$REPLY_TEXT" | grep -q "^TOOLS:"; then
    TOOL_NAMES=$(echo "$REPLY_TEXT" | grep "^TOOLS:" | head -1 | sed 's/^TOOLS://')
    if [[ "$TOOL_NAMES" != "none" && -n "$TOOL_NAMES" ]]; then
      HAS_TOOL_CALLS=true
    fi
  fi

  REPLY_BODY=$(echo "$REPLY_TEXT" | grep "^TEXT:" | head -1 | sed 's/^TEXT://')
  rm -f "$tmpfile"
}

# Create a fresh session for testing
new_session() {
  local sid
  sid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
  echo "$sid"
}

# Check for narration patterns in response
has_narration() {
  local text="$1"
  local lower
  lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
  for pattern in "creating " "saved as" "i'll " "let me " "i've created" "file has been" "listing " "checking "; do
    if echo "$lower" | grep -q "$pattern"; then
      return 0
    fi
  done
  return 1
}

# ---------- Preflight ----------
log "=== PWA Live Battle Test base=$BASE timeout=${TIMEOUT}s ==="

# Check server is up
if ! curl -sS --max-time 5 "${BASE}/api/health" > /dev/null 2>&1; then
  log "ABORT: Chump web server not reachable at $BASE"
  log "Start it: CHUMP_WEB_PORT=$PORT ./run-web.sh"
  exit 3
fi
log "Server reachable at $BASE"

# ---------- Scenario 1: Greeting (no hallucination) ----------
log ""
log "--- Scenario 1: Greeting (should not hallucinate actions) ---"
SID=$(new_session)
send_chat "$SID" "hello"
if [[ "$HAS_TOOL_CALLS" == "true" ]]; then
  warn "S1: greeting triggered tool calls ($TOOL_NAMES) — wasteful but not broken"
elif has_narration "$REPLY_BODY"; then
  fail "S1: greeting produced narration: ${REPLY_BODY:0:200}"
elif [[ -n "$REPLY_BODY" ]]; then
  pass "S1: clean greeting response"
else
  fail "S1: empty response to greeting"
fi

# ---------- Scenario 2: Math question (fast path) ----------
log ""
log "--- Scenario 2: Math question (should answer directly) ---"
SID=$(new_session)
send_chat "$SID" "What is 2 + 2?"
if echo "$REPLY_BODY" | grep -qi "4"; then
  pass "S2: correct math answer"
elif has_narration "$REPLY_BODY"; then
  fail "S2: narrated instead of answering: ${REPLY_BODY:0:200}"
else
  warn "S2: got response but no '4': ${REPLY_BODY:0:200}"
fi

# ---------- Scenario 3: Task creation (MUST use tool) ----------
log ""
log "--- Scenario 3: Task creation (must call task tool) ---"
SID=$(new_session)
send_chat "$SID" "create a task called battle-test-probe"
if [[ "$HAS_TOOL_CALLS" == "true" ]]; then
  pass "S3: tool call made ($TOOL_NAMES)"
elif has_narration "$REPLY_BODY"; then
  fail "S3: narrated task creation instead of calling tool: ${REPLY_BODY:0:200}"
else
  warn "S3: no tool call, but also no narration: ${REPLY_BODY:0:200}"
fi

# ---------- Scenario 4: Task listing (MUST use tool) ----------
log ""
log "--- Scenario 4: Task listing (must call task tool) ---"
SID=$(new_session)
send_chat "$SID" "list my tasks"
if [[ "$HAS_TOOL_CALLS" == "true" ]]; then
  pass "S4: tool call made ($TOOL_NAMES)"
elif has_narration "$REPLY_BODY"; then
  fail "S4: narrated instead of listing: ${REPLY_BODY:0:200}"
else
  warn "S4: responded without tool call: ${REPLY_BODY:0:200}"
fi

# ---------- Scenario 5: File creation (MUST use write_file) ----------
log ""
log "--- Scenario 5: File creation (must call write_file) ---"
SID=$(new_session)
send_chat "$SID" "create a file called /tmp/chump-battle-test.txt with the content hello world"
if [[ "$HAS_TOOL_CALLS" == "true" ]]; then
  if echo "$TOOL_NAMES" | grep -qi "write_file\|write\|file"; then
    pass "S5: write_file tool called ($TOOL_NAMES)"
  else
    warn "S5: tool called but not write_file: $TOOL_NAMES"
  fi
elif has_narration "$REPLY_BODY"; then
  fail "S5: narrated file creation instead of calling tool: ${REPLY_BODY:0:200}"
else
  warn "S5: no tool call for file creation: ${REPLY_BODY:0:200}"
fi

# ---------- Scenario 6: Multi-turn task close ----------
log ""
log "--- Scenario 6: Multi-turn task close ---"
SID=$(new_session)
send_chat "$SID" "what tasks are open"
FIRST_TOOL="$HAS_TOOL_CALLS"
if [[ "$FIRST_TOOL" == "true" ]]; then
  log "  S6a: listed tasks via tool ($TOOL_NAMES)"
else
  log "  S6a: no tool call for task listing"
fi
# Now try to close one
send_chat "$SID" "close the first task"
if [[ "$HAS_TOOL_CALLS" == "true" ]]; then
  pass "S6: multi-turn close used tool ($TOOL_NAMES)"
elif has_narration "$REPLY_BODY"; then
  fail "S6: narrated task close: ${REPLY_BODY:0:200}"
else
  warn "S6: no tool for close: ${REPLY_BODY:0:200}"
fi

# ---------- Scenario 7: Self-awareness (no tools needed) ----------
log ""
log "--- Scenario 7: Self-awareness question ---"
SID=$(new_session)
send_chat "$SID" "what are you"
if has_narration "$REPLY_BODY"; then
  fail "S7: narrated instead of answering: ${REPLY_BODY:0:200}"
elif [[ -n "$REPLY_BODY" ]]; then
  pass "S7: answered identity question"
else
  fail "S7: empty response"
fi

# ---------- Results ----------
log ""
log "==========================================="
TOTAL=$((PASSES + FAILS + WARNS))
log "RESULTS: $PASSES pass, $FAILS fail, $WARNS warn (out of $TOTAL scenarios)"
SCORE=0
if [[ $TOTAL -gt 0 ]]; then
  SCORE=$(( (PASSES * 100) / TOTAL ))
fi
log "SCORE: ${SCORE}%"

if [[ $FAILS -gt 0 ]]; then
  log "STATUS: NEEDS WORK — $FAILS scenarios failed"
  exit 1
elif [[ $WARNS -gt 0 ]]; then
  log "STATUS: ACCEPTABLE — $WARNS warnings, investigate"
  exit 0
else
  log "STATUS: ALL CLEAR"
  exit 0
fi
