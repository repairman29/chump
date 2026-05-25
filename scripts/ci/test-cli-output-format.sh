#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-cli-output-format.sh — EFFECTIVE-008 CLI output format consistency
#
# Tests:
#   1. chump gap list --json → valid JSON array
#   2. chump gap list --json | jq '.[] | .id' → gap IDs
#   3. chump gap list --format json (same as --json)
#   4. chump gap list --format csv → CSV with header
#   5. chump gap list --quiet → exit 0, no stdout
#   6. chump gap list --format human → human-readable [status] lines
#   7. CLI_FLAGS.md documents --quiet and --format

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== EFFECTIVE-008: CLI output format consistency ==="

# ── Locate chump binary ───────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
  if [[ -f "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
    CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
  elif command -v chump &>/dev/null; then
    CHUMP_BIN="$(command -v chump)"
  fi
fi

# ── Set up synthetic state.db ─────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
FAKE_REPO="$TMPDIR_TEST/repo"
mkdir -p "$FAKE_REPO/.chump"

sqlite3 "$FAKE_REPO/.chump/state.db" <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT 'P2',
  effort TEXT NOT NULL DEFAULT 'm',
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
CREATE TABLE leases (
  session_id TEXT PRIMARY KEY,
  gap_id TEXT NOT NULL DEFAULT '',
  worktree TEXT NOT NULL DEFAULT '',
  expires_at INTEGER NOT NULL DEFAULT 0
);
INSERT INTO gaps(id,domain,title,status,priority,effort)
VALUES('TEST-001','TEST','First test gap','open','P1','s');
INSERT INTO gaps(id,domain,title,status,priority,effort)
VALUES('TEST-002','TEST','Second test gap','open','P2','m');
SQL

if [[ -z "$CHUMP_BIN" ]]; then
  echo "WARN: chump binary not built — structural tests only"
fi

_chump() {
  if [[ -n "$CHUMP_BIN" ]]; then
    CHUMP_REPO="$FAKE_REPO" "$CHUMP_BIN" "$@" 2>&1
  else
    echo "(skipped — no chump binary)"
  fi
}

# ── Test 1: --json produces valid JSON ────────────────────────────────────────
echo "--- 1. gap list --json produces valid JSON"
if [[ -n "$CHUMP_BIN" ]]; then
  json_out="$(_chump gap list --json --include-test-domains 2>&1 || true)"
  if echo "$json_out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)" 2>/dev/null; then
    ok "gap list --json → valid JSON array"
  else
    fail "gap list --json did not produce valid JSON (got: ${json_out:0:100})"
  fi
else
  ok "skip (no binary)"
fi

# ── Test 2: --json | jq extracts IDs ─────────────────────────────────────────
echo "--- 2. gap list --json | jq extracts gap IDs"
if [[ -n "$CHUMP_BIN" ]] && command -v jq &>/dev/null; then
  ids="$(CHUMP_REPO="$FAKE_REPO" "$CHUMP_BIN" gap list --json --include-test-domains 2>/dev/null \
      | jq -r '.[] | .id' 2>/dev/null || true)"
  if echo "$ids" | grep -q 'TEST-001'; then
    ok "gap list --json | jq '.[] | .id' extracts gap IDs"
  else
    fail "jq extraction failed (got: $ids)"
  fi
else
  ok "skip (no binary or jq)"
fi

# ── Test 3: --format json same as --json ─────────────────────────────────────
echo "--- 3. gap list --format json = --json"
if [[ -n "$CHUMP_BIN" ]]; then
  fmt_out="$(_chump gap list --format json --include-test-domains 2>&1 || true)"
  if echo "$fmt_out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    ok "gap list --format json produces valid JSON"
  else
    fail "gap list --format json did not produce valid JSON"
  fi
else
  ok "skip (no binary)"
fi

# ── Test 4: --format csv has CSV header ──────────────────────────────────────
echo "--- 4. gap list --format csv"
if [[ -n "$CHUMP_BIN" ]]; then
  csv_out="$(_chump gap list --format csv --include-test-domains 2>&1 || true)"
  if echo "$csv_out" | head -1 | grep -q 'id,domain,status'; then
    ok "gap list --format csv has CSV header"
  else
    fail "gap list --format csv missing CSV header (got: ${csv_out:0:100})"
  fi
  if echo "$csv_out" | grep -q 'TEST-001'; then
    ok "gap list --format csv contains gap data"
  else
    fail "gap list --format csv missing gap data"
  fi
else
  ok "skip (no binary)"
fi

# ── Test 5: --quiet → exit 0, no stdout ──────────────────────────────────────
echo "--- 5. gap list --quiet → exit 0, no output"
if [[ -n "$CHUMP_BIN" ]]; then
  quiet_out="$(CHUMP_REPO="$FAKE_REPO" "$CHUMP_BIN" gap list --quiet --include-test-domains 2>/dev/null || true)"
  if [[ -z "$quiet_out" ]]; then
    ok "gap list --quiet produces no stdout"
  else
    fail "gap list --quiet produced unexpected output: '${quiet_out:0:80}'"
  fi
  if CHUMP_REPO="$FAKE_REPO" "$CHUMP_BIN" gap list --quiet --include-test-domains >/dev/null 2>&1; then
    ok "gap list --quiet exits 0"
  else
    fail "gap list --quiet exited non-zero"
  fi
else
  ok "skip (no binary)"
fi

# ── Test 6: --format human → [status] lines ──────────────────────────────────
echo "--- 6. gap list --format human"
if [[ -n "$CHUMP_BIN" ]]; then
  human_out="$(_chump gap list --format human --include-test-domains 2>&1 || true)"
  if echo "$human_out" | grep -q '\[open\]'; then
    ok "gap list --format human produces [open] lines"
  else
    fail "gap list --format human missing [open] lines (got: ${human_out:0:100})"
  fi
else
  ok "skip (no binary)"
fi

# ── Test 7: CLI_FLAGS.md documents --quiet and --format ──────────────────────
echo "--- 7. CLI_FLAGS.md documentation"
FLAGS_DOC="$REPO_ROOT/docs/CLI_FLAGS.md"
if [[ -f "$FLAGS_DOC" ]]; then
  if grep -q '\-\-format' "$FLAGS_DOC"; then
    ok "CLI_FLAGS.md documents --format flag"
  else
    fail "CLI_FLAGS.md missing --format documentation"
  fi
  if grep -q '\-\-quiet' "$FLAGS_DOC" && grep -q 'gap list' "$FLAGS_DOC"; then
    ok "CLI_FLAGS.md documents --quiet for gap list"
  else
    fail "CLI_FLAGS.md missing --quiet/gap list documentation"
  fi
  if grep -q 'csv' "$FLAGS_DOC"; then
    ok "CLI_FLAGS.md mentions csv format"
  else
    fail "CLI_FLAGS.md missing csv format mention"
  fi
else
  fail "CLI_FLAGS.md not found at $FLAGS_DOC"
fi

# ── Test 8: EFFECTIVE-008 reference in main.rs ───────────────────────────────
echo "--- 8. EFFECTIVE-008 reference in source"
if grep -q 'EFFECTIVE-008' "$REPO_ROOT/src/main.rs"; then
  ok "EFFECTIVE-008 referenced in src/main.rs"
else
  fail "EFFECTIVE-008 reference missing from src/main.rs"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "EFFECTIVE-008 CI gate FAILED"
  exit 1
fi
echo "EFFECTIVE-008 CI gate PASSED"
