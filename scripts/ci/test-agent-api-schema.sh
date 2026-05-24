#!/usr/bin/env bash
# test-agent-api-schema.sh — INFRA-1548
#
# Asserts schema_version=1 is present in all three contracted JSON outputs:
#   1. chump --briefing <GAP-ID> --json
#   2. chump health --json
#   3. chump gap show <GAP-ID> --json
#
# Uses a known-good test gap (first open gap from state.db, or INFRA-1548
# if available) to drive chump --briefing and chump gap show.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CHUMP="${CHUMP:-$REPO_ROOT/target/debug/chump}"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Require the chump binary
if [[ ! -x "$CHUMP" ]]; then
  echo "SKIP: chump binary not found at $CHUMP — build first"
  exit 0
fi

# Pick a test gap ID: prefer one that actually exists in state.db
TEST_GAP=$(cd "$REPO_ROOT" && "$CHUMP" gap list --status open --json 2>/dev/null \
  | python3 -c "import json,sys; gs=json.load(sys.stdin); print(gs[0]['id'] if gs else '')" 2>/dev/null || true)

if [[ -z "$TEST_GAP" ]]; then
  echo "SKIP: no open gaps in state.db — cannot test --briefing / gap show"
  # Still test health --json
  echo "Test 1: chump health --json contains schema_version=1"
  health_out=$(cd "$REPO_ROOT" && "$CHUMP" health --json 2>/dev/null || true)
  sv=$(echo "$health_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('schema_version','MISSING'))" 2>/dev/null || echo "MISSING")
  if [[ "$sv" == "1" ]]; then
    ok "health --json schema_version=1"
  else
    fail "health --json schema_version=$sv (expected 1)"
  fi
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]] && echo "PASS" && exit 0 || exit 1
fi

echo "Using test gap: $TEST_GAP"
echo ""

# ── Test 1: chump --briefing <ID> --json ──────────────────────────────────────
echo "Test 1: chump --briefing $TEST_GAP --json contains schema_version=1"
briefing_out=$(cd "$REPO_ROOT" && "$CHUMP" --briefing "$TEST_GAP" --json 2>/dev/null || true)
if [[ -n "$briefing_out" ]]; then
  sv=$(echo "$briefing_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('schema_version','MISSING'))" 2>/dev/null || echo "MISSING")
  if [[ "$sv" == "1" ]]; then
    ok "--briefing --json schema_version=1"
  else
    fail "--briefing --json schema_version=$sv (expected 1)"
  fi
else
  fail "--briefing --json produced no output"
fi

# ── Test 2: chump health --json ────────────────────────────────────────────────
echo "Test 2: chump health --json contains schema_version=1"
health_out=$(cd "$REPO_ROOT" && "$CHUMP" health --json 2>/dev/null || true)
if [[ -n "$health_out" ]]; then
  sv=$(echo "$health_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('schema_version','MISSING'))" 2>/dev/null || echo "MISSING")
  if [[ "$sv" == "1" ]]; then
    ok "health --json schema_version=1"
  else
    fail "health --json schema_version=$sv (expected 1)"
  fi
else
  fail "health --json produced no output"
fi

# ── Test 3: chump gap show <ID> --json ────────────────────────────────────────
echo "Test 3: chump gap show $TEST_GAP --json contains schema_version=1"
show_out=$(cd "$REPO_ROOT" && "$CHUMP" gap show "$TEST_GAP" --json 2>/dev/null || true)
if [[ -n "$show_out" ]]; then
  sv=$(echo "$show_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('schema_version','MISSING'))" 2>/dev/null || echo "MISSING")
  if [[ "$sv" == "1" ]]; then
    ok "gap show --json schema_version=1"
  else
    fail "gap show --json schema_version=$sv (expected 1)"
  fi
else
  fail "gap show --json produced no output"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: schema_version=1 missing from one or more JSON outputs"
  exit 1
fi
echo "PASS: all agent-API JSON outputs carry schema_version=1"
exit 0
