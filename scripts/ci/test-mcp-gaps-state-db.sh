#!/usr/bin/env bash
# test-mcp-gaps-state-db.sh — AC test for INFRA-628
# Verifies chump-mcp-gaps reads .chump/state.db (not docs/gaps.yaml).
# Creates a synthetic SQLite-only registry in a temp dir, runs live JSON-RPC
# calls against the built binary, and asserts expected results.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve the binary — workspace may use a non-default target dir
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
  BIN="$CARGO_TARGET_DIR/debug/chump-mcp-gaps"
elif [[ -f "$HOME/.cache/chump-fleet-target/debug/chump-mcp-gaps" ]]; then
  BIN="$HOME/.cache/chump-fleet-target/debug/chump-mcp-gaps"
else
  BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump-mcp-gaps"
fi

if [[ ! -x "$BIN" ]]; then
  echo "building chump-mcp-gaps..."
  (cd "$REPO_ROOT" && cargo build -p chump-mcp-gaps --quiet 2>&1)
  # re-resolve after build
  if [[ ! -x "$BIN" ]]; then
    BIN="$(cd "$REPO_ROOT" && cargo build -p chump-mcp-gaps --message-format=json 2>/dev/null \
      | python3 -c "import sys,json; [print(o['executable']) for l in sys.stdin for o in [json.loads(l)] if o.get('reason')=='compiler-artifact' and o.get('executable') and 'chump-mcp-gaps' in (o.get('executable') or '')]" | tail -1)"
  fi
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/.chump"
DB="$TMPDIR_TEST/.chump/state.db"

sqlite3 "$DB" <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY, domain TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT '', effort TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  acceptance_criteria TEXT NOT NULL DEFAULT '',
  depends_on TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '',
  source_doc TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0,
  closed_at INTEGER, opened_date TEXT NOT NULL DEFAULT '',
  closed_date TEXT NOT NULL DEFAULT '', closed_pr INTEGER,
  skills_required TEXT NOT NULL DEFAULT '',
  preferred_backend TEXT NOT NULL DEFAULT '',
  preferred_machine TEXT NOT NULL DEFAULT '',
  estimated_minutes TEXT NOT NULL DEFAULT '',
  required_model TEXT NOT NULL DEFAULT ''
);
CREATE TABLE gap_counters (domain TEXT PRIMARY KEY, next_num INTEGER NOT NULL DEFAULT 1);
INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria)
  VALUES ('TEST-001', 'TEST', 'EFFECTIVE: alpha gap', 'P1', 's', 'open', 'AC: works');
INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria)
  VALUES ('TEST-002', 'TEST', 'RESILIENT: beta gap', 'P2', 'm', 'open', 'AC: stable');
INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria)
  VALUES ('TEST-003', 'TEST', 'closed gap', 'P1', 'xs', 'closed', 'AC: done');
SQL

rpc() {
  local req="$1"
  echo "$req" | CHUMP_REPO="$TMPDIR_TEST" "$BIN"
}

fail() { echo "FAIL: $1"; exit 1; }

# list_open_gaps — should return 2 open gaps
OUT=$(rpc '{"jsonrpc":"2.0","method":"list_open_gaps","params":{},"id":1}')
COUNT=$(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['count'])")
[[ "$COUNT" == "2" ]] || fail "list_open_gaps count expected 2, got $COUNT"

# list_open_gaps with priority filter P1 — should return 1
OUT=$(rpc '{"jsonrpc":"2.0","method":"list_open_gaps","params":{"priority":"P1"},"id":2}')
COUNT=$(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['count'])")
[[ "$COUNT" == "1" ]] || fail "list_open_gaps P1 count expected 1, got $COUNT"

# get_gap by full id
OUT=$(rpc '{"jsonrpc":"2.0","method":"get_gap","params":{"gap_id":"TEST-001"},"id":3}')
TITLE=$(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['gap']['title'])")
[[ "$TITLE" == "EFFECTIVE: alpha gap" ]] || fail "get_gap title mismatch: $TITLE"

# get_gap by short suffix
OUT=$(rpc '{"jsonrpc":"2.0","method":"get_gap","params":{"gap_id":"002"},"id":4}')
TITLE=$(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['gap']['title'])")
[[ "$TITLE" == "RESILIENT: beta gap" ]] || fail "get_gap suffix title mismatch: $TITLE"

# get_gap not found
OUT=$(rpc '{"jsonrpc":"2.0","method":"get_gap","params":{"gap_id":"TEST-999"},"id":5}')
SUCCESS=$(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['success'])")
[[ "$SUCCESS" == "False" ]] || fail "get_gap 999 should be not found"

# docs/gaps.yaml must NOT exist in synthetic dir (backward compat: state.db is canonical)
[[ ! -f "$TMPDIR_TEST/docs/gaps.yaml" ]] || fail "test env should not have docs/gaps.yaml"

echo "PASS: all chump-mcp-gaps state.db tests passed"
