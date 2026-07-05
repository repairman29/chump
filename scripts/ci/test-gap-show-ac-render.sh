#!/usr/bin/env bash
# CI gate for CREDIBLE-033: chump gap show renders acceptance_criteria as numbered list.
# Tests: numbered list, JSON ac_count, JSON ac_has_todos, WARN prefix on TODO AC.
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHUMP="${CHUMP_BIN:-${REPO_ROOT}/target/debug/chump}"

if [[ ! -x "$CHUMP" ]]; then
  echo "SKIP: chump binary not found at $CHUMP"
  exit 0
fi

echo "=== CREDIBLE-033: chump gap show AC rendering CI gate ==="
echo

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.chump"

sqlite3 "$FAKE_REPO/.chump/state.db" << 'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT 'P1',
  effort TEXT NOT NULL DEFAULT 's',
  status TEXT NOT NULL DEFAULT 'open',
  acceptance_criteria TEXT NOT NULL DEFAULT '',
  depends_on TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  source_doc TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL DEFAULT 0,
  closed_at INTEGER,
  opened_date TEXT NOT NULL DEFAULT '',
  closed_date TEXT NOT NULL DEFAULT '',
  closed_pr INTEGER,
  skills_required TEXT NOT NULL DEFAULT '',
  preferred_backend TEXT NOT NULL DEFAULT '',
  preferred_machine TEXT NOT NULL DEFAULT '',
  estimated_minutes TEXT NOT NULL DEFAULT '',
  required_model TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps (id, domain, title, status, acceptance_criteria) VALUES
  -- 2 concrete AC items
  ('CREDIBLE-T01', 'CREDIBLE', 'gap with concrete two-item AC', 'open',
   '["cargo test passes without error","CI script exits 0 on success"]'),
  -- 1 TODO placeholder AC
  ('CREDIBLE-T02', 'CREDIBLE', 'gap with TODO acceptance criteria', 'open',
   '["TODO: fill in acceptance criteria after design review"]'),
  -- mix: 1 good + 1 TBD
  ('CREDIBLE-T03', 'CREDIBLE', 'gap with mixed AC', 'open',
   '["chump gap show renders numbered list","TBD: measure performance impact"]');
SQL

echo "[1. Text output: AC rendered as numbered list (not raw JSON)]"
out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap show CREDIBLE-T01 2>/dev/null || true)
# Should see "1." and "2." but NOT raw "[" or "]"
if echo "$out" | grep -qE "^\s+1\."; then
  ok "first AC item starts with '1.'"
else
  fail "first AC item not numbered: $out"
fi
if echo "$out" | grep -qE "^\s+2\."; then
  ok "second AC item starts with '2.'"
else
  fail "second AC item not numbered: $out"
fi
if echo "$out" | grep -q "cargo test passes"; then
  ok "AC text content is readable (not bracket-encoded)"
else
  fail "AC text content missing or bracket-encoded: $out"
fi

echo
echo "[2. JSON output: ac_count field present]"
json_out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap show CREDIBLE-T01 --json 2>/dev/null || true)
if echo "$json_out" | python3 -c "
import sys, json
g = json.loads(sys.stdin.read())
assert 'ac_count' in g, 'missing ac_count'
assert g['ac_count'] == 2, f'expected 2, got {g[\"ac_count\"]}'
" 2>/dev/null; then
  ok "--json includes ac_count=2 for 2-item AC gap"
else
  fail "--json ac_count missing or wrong: $json_out"
fi

echo
echo "[3. JSON output: ac_has_todos is false for clean gap]"
if echo "$json_out" | python3 -c "
import sys, json
g = json.loads(sys.stdin.read())
assert 'ac_has_todos' in g, 'missing ac_has_todos'
assert g['ac_has_todos'] == False, f'expected False, got {g[\"ac_has_todos\"]}'
" 2>/dev/null; then
  ok "--json ac_has_todos=false for clean gap"
else
  fail "--json ac_has_todos wrong for clean gap: $json_out"
fi

echo
echo "[4. WARN prefix on TODO AC item in text output]"
todo_out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap show CREDIBLE-T02 2>&1 || true)
if echo "$todo_out" | grep -q "WARN:"; then
  ok "WARN prefix present in output for TODO AC gap"
else
  fail "WARN prefix missing for TODO AC gap: $todo_out"
fi

echo
echo "[5. JSON ac_has_todos=true for TODO AC gap]"
todo_json=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap show CREDIBLE-T02 --json 2>/dev/null || true)
if echo "$todo_json" | python3 -c "
import sys, json
g = json.loads(sys.stdin.read())
assert g.get('ac_has_todos') == True, f'expected True, got {g.get(\"ac_has_todos\")}'
" 2>/dev/null; then
  ok "--json ac_has_todos=true for TODO AC gap"
else
  fail "--json ac_has_todos wrong for TODO gap: $todo_json"
fi

echo
echo "[6. Mixed AC: only the TBD item shows WARN prefix]"
mixed_out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap show CREDIBLE-T03 2>&1 || true)
# Item 1 (concrete) should NOT have WARN
# Item 2 (TBD) should have WARN
if echo "$mixed_out" | grep -qE "^\s+1\. chump gap show"; then
  ok "concrete item 1 renders without WARN"
else
  fail "concrete item 1 not rendered correctly: $mixed_out"
fi
if echo "$mixed_out" | grep -qE "^\s+2\. WARN:"; then
  ok "TBD item 2 has WARN prefix"
else
  fail "TBD item 2 missing WARN prefix: $mixed_out"
fi

echo
echo "[7. CREDIBLE-033 referenced in source]"
if grep -r "CREDIBLE-033" "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null | grep -q "CREDIBLE-033"; then
  ok "CREDIBLE-033 referenced in src/main.rs"
else
  fail "CREDIBLE-033 not found in src/main.rs"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
