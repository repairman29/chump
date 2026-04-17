#!/usr/bin/env bash
# test-acp-smoke.sh — ACP protocol smoke test (ACP-003).
#
# Drives the chump --acp binary with JSON-RPC messages and validates the
# responses match the expected protocol shape. Covers:
#   1. initialize          → agentCapabilities JSON
#   2. session/new         → sessionId string
#   3. session/list        → sessions array
#
# Does NOT test session/prompt (requires a live model). That path is covered by
# the battle-qa suite when OPENAI_API_BASE is available.
#
# Usage:
#   ./scripts/test-acp-smoke.sh                     # uses debug build
#   CHUMP_BIN=./target/release/chump ./scripts/test-acp-smoke.sh
#
# Exit: 0 if all checks pass, 1 otherwise. Errors go to stderr.
set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
  if [[ -x "$ROOT/target/release/chump" ]]; then
    CHUMP_BIN="$ROOT/target/release/chump"
  elif [[ -x "$ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$ROOT/target/debug/chump"
  else
    echo "ERROR: no chump binary found; run 'cargo build' first" >&2
    exit 1
  fi
fi

PASS=0
FAIL=0
ERRORS=()

check() {
  local label="$1"
  local value="$2"
  local expect="$3"
  if [[ "$value" == "$expect" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — got '$value', expected '$expect'" >&2
    FAIL=$((FAIL + 1))
    ERRORS+=("$label")
  fi
}

check_nonempty() {
  local label="$1"
  local value="$2"
  if [[ -n "$value" ]] && [[ "$value" != "null" ]] && [[ "$value" != "{}" ]]; then
    echo "  PASS: $label (non-empty)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — empty or null" >&2
    FAIL=$((FAIL + 1))
    ERRORS+=("$label")
  fi
}

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required for ACP smoke test" >&2
  exit 1
fi

# ── Build JSON-RPC messages ───────────────────────────────────────────────────
# session/new requires cwd param (required field per NewSessionRequest).
CWD="$(pwd)"

MSG_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"0.1","clientInfo":{"name":"smoke-test","version":"0.0.1"},"capabilities":{}}}'
MSG_SESSION_NEW="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"$CWD\"}}"
MSG_SESSION_LIST='{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}'

MESSAGES="$MSG_INIT
$MSG_SESSION_NEW
$MSG_SESSION_LIST"

# ── Run ACP server with piped messages ───────────────────────────────────────
TMPOUT=$(mktemp)
TMPDIR_SESSION=$(mktemp -d)
trap 'rm -f "$TMPOUT"; rm -rf "$TMPDIR_SESSION"' EXIT

echo "=== ACP Smoke Test ==="
echo "Binary: $CHUMP_BIN"
echo "Sending 3 messages: initialize, session/new, session/list"
echo ""

if command -v timeout &>/dev/null; then
  echo "$MESSAGES" | CHUMP_HOME="$TMPDIR_SESSION" timeout 15 "$CHUMP_BIN" --acp > "$TMPOUT" 2>/dev/null || true
else
  echo "$MESSAGES" | CHUMP_HOME="$TMPDIR_SESSION" "$CHUMP_BIN" --acp > "$TMPOUT" 2>/dev/null &
  ACP_PID=$!
  sleep 8
  kill "$ACP_PID" 2>/dev/null || true
  wait "$ACP_PID" 2>/dev/null || true
fi

if [[ ! -s "$TMPOUT" ]]; then
  echo "FAIL: No output from chump --acp" >&2
  exit 1
fi

# ── Extract responses by id (responses may arrive out of order) ──────────────
# Filter out non-JSON lines (e.g. tracing noise on stdout).
VALID_JSON=$(grep -E '^\{.*\}$' "$TMPOUT" 2>/dev/null || true)
LINE_COUNT=$(echo "$VALID_JSON" | grep -c '^{' 2>/dev/null || echo 0)

if [[ "$LINE_COUNT" -lt 2 ]]; then
  echo "FAIL: Expected at least 2 JSON response lines, got $LINE_COUNT" >&2
  echo "Raw output:" >&2
  cat "$TMPOUT" >&2
  exit 1
fi

# Extract response by JSON-RPC id (sort-by-id for determinism).
get_by_id() {
  local id="$1"
  echo "$VALID_JSON" | jq -c "select(.id == $id)" 2>/dev/null | head -1
}

R1=$(get_by_id 1)
R2=$(get_by_id 2)
R3=$(get_by_id 3)

# ── Validate initialize response ─────────────────────────────────────────────
echo "--- Response id=1 (initialize) ---"
echo "$R1" | jq '.' 2>/dev/null || echo "$R1"
echo ""

R1_ERROR=$(echo "$R1" | jq -r '.error // empty' 2>/dev/null)
R1_CAPS=$(echo "$R1" | jq -r '.result.agentCapabilities // empty' 2>/dev/null)
R1_PROTO=$(echo "$R1" | jq -r '.result.protocolVersion // empty' 2>/dev/null)

check "initialize: no error" "${R1_ERROR:-}" ""
check_nonempty "initialize: agentCapabilities present" "$R1_CAPS"
check_nonempty "initialize: protocolVersion present" "$R1_PROTO"

# ── Validate session/new response ────────────────────────────────────────────
echo "--- Response id=2 (session/new) ---"
echo "$R2" | jq '.' 2>/dev/null || echo "$R2"
echo ""

R2_ERROR=$(echo "$R2" | jq -r '.error // empty' 2>/dev/null)
R2_SID=$(echo "$R2" | jq -r '.result.sessionId // empty' 2>/dev/null)

check "session/new: no error" "${R2_ERROR:-}" ""
check_nonempty "session/new: sessionId present" "$R2_SID"

# ── Validate session/list response ───────────────────────────────────────────
if [[ -n "$R3" ]]; then
  echo "--- Response id=3 (session/list) ---"
  echo "$R3" | jq '.' 2>/dev/null || echo "$R3"
  echo ""

  R3_ERROR=$(echo "$R3" | jq -r '.error // empty' 2>/dev/null)
  R3_SESSIONS=$(echo "$R3" | jq -r '.result.sessions // empty' 2>/dev/null)

  check "session/list: no error" "${R3_ERROR:-}" ""
  check_nonempty "session/list: sessions field present" "$R3_SESSIONS"

  # Cross-check: newly created session may appear in list (best-effort; async persistence).
  if [[ -n "$R2_SID" ]]; then
    R3_HAS_SID=$(echo "$R3" | jq -r --arg sid "$R2_SID" \
      '.result.sessions[]? | select(.sessionId == $sid) | .sessionId' 2>/dev/null)
    if [[ -n "$R3_HAS_SID" ]]; then
      echo "  PASS: session/list: contains newly created session $R2_SID"
      PASS=$((PASS + 1))
    else
      echo "  INFO: session/list: session $R2_SID not yet in list (async persistence; not a failure)"
    fi
  fi
fi

# ── Write snapshot fixtures ───────────────────────────────────────────────────
FIXTURE_DIR="$ROOT/tests/fixtures/acp"
mkdir -p "$FIXTURE_DIR"

# Capture the response shape (keys only) as a deterministic snapshot.
echo "$R1" | jq '{jsonrpc,id,result_keys: (.result | keys)}' \
  > "$FIXTURE_DIR/initialize_shape.json" 2>/dev/null || true
echo "$R2" | jq '{jsonrpc,id,result_keys: (.result | keys)}' \
  > "$FIXTURE_DIR/session_new_shape.json" 2>/dev/null || true

echo ""
echo "Snapshots written to $FIXTURE_DIR/"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  for e in "${ERRORS[@]}"; do
    echo "  FAIL: $e"
  done
  exit 1
fi
exit 0
