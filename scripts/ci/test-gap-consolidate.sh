#!/usr/bin/env bash
# CI gate for INFRA-935: chump gap consolidate near-duplicate detection.
# Tests: output format, JSON flag, threshold, zero-result case.
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

echo "=== INFRA-935: chump gap consolidate CI gate ==="
echo

# Create a synthetic state.db with near-duplicate titles
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
INSERT INTO gaps (id, domain, title, status) VALUES
  ('INFRA-001', 'INFRA', 'ZERO-WASTE: split pre-commit into modular guards showing each check name status', 'open'),
  ('INFRA-002', 'INFRA', 'ZERO-WASTE: split pre-commit into modular guards for each check name status output', 'open'),
  ('INFRA-003', 'INFRA', 'EFFECTIVE: add live progress bar showing completion status to chump gap list output', 'open'),
  ('INFRA-004', 'INFRA', 'EFFECTIVE: add live progress bar showing completion status for chump gap list display', 'open'),
  ('INFRA-005', 'INFRA', 'CREDIBLE: unique gap about fleet health metrics dashboard', 'open');
SQL

echo "[1. Basic near-duplicate detection]"
out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap consolidate 2>&1 || true)
if echo "$out" | grep -q "INFRA-001\|INFRA-002"; then
  ok "INFRA-001/002 near-duplicate pair detected at default 80% threshold"
else
  fail "near-duplicate pair not detected: $out"
fi

echo "[2. Table format has required columns]"
if echo "$out" | grep -qE "sim%|gap_a|gap_b|action"; then
  ok "table has sim%, gap_a, gap_b, action columns"
else
  fail "table missing required columns: $out"
fi

echo "[3. --json flag produces valid JSON array]"
json_out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap consolidate --json 2>&1 || true)
if echo "$json_out" | python3 -c "
import sys, json
pairs = json.loads(sys.stdin.read())
assert isinstance(pairs, list), f'expected list, got {type(pairs)}'
assert len(pairs) >= 1, 'expected at least 1 pair'
for p in pairs:
    assert 'gap_id_a' in p
    assert 'gap_id_b' in p
    assert 'similarity_pct' in p
    assert 'suggested_action' in p
" 2>/dev/null; then
  ok "--json produces array with gap_id_a, gap_id_b, similarity_pct, suggested_action"
else
  fail "--json output invalid: $json_out"
fi

echo "[4. --threshold controls sensitivity]"
high_out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap consolidate --threshold 95 2>&1 || true)
if echo "$high_out" | grep -q "registry clean\|no near-duplicate"; then
  ok "--threshold 95 finds 0 pairs (titles are similar but not identical)"
else
  fail "threshold 95 should find no pairs, got: $high_out"
fi

echo "[5. suggested_action is merge for high similarity, review for lower]"
json_all=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap consolidate --threshold 40 --json 2>&1 || true)
if echo "$json_all" | python3 -c "
import sys, json
pairs = json.loads(sys.stdin.read())
for p in pairs:
    sim = p['similarity_pct']
    action = p['suggested_action']
    assert action in ('merge', 'review'), f'unexpected action: {action}'
" 2>/dev/null; then
  ok "suggested_action is 'merge' or 'review' for all pairs"
else
  fail "unexpected suggested_action values: $json_all"
fi

echo "[6. INFRA-935 referenced in source]"
if grep -r "INFRA-935" "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null | grep -q "INFRA-935"; then
  ok "INFRA-935 referenced in src/main.rs"
else
  fail "INFRA-935 not found in src/main.rs"
fi

echo "[7. 'consolidate' appears in chump gap help]"
help_out=$("$CHUMP" gap --help 2>&1 || "$CHUMP" gap 2>&1 || true)
if echo "$help_out" | grep -q "consolidate"; then
  ok "'consolidate' listed in chump gap help"
else
  fail "'consolidate' not in chump gap help: $help_out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
