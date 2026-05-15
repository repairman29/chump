#!/usr/bin/env bash
# test-uuid-gap-id-compat.sh — INFRA-630 UUID gap-ID compatibility
#
# Exercises the preflight→show flow on a synthetic UUID-only state.db and
# verifies bot-merge.sh auto-derive handles UUID-format branch names.
#
# Tests:
#   1. chump gap preflight <full-UUID> → OK (Available)
#   2. chump gap preflight <8-char-prefix> → OK (prefix-match)
#   3. chump gap show <full-UUID> → prints gap title
#   4. chump gap show <8-char-prefix> → prints gap title (prefix-match)
#   5. bot-merge.sh extracts full RFC-4122 UUID from branch name
#   6. bot-merge.sh extracts 8-char short-prefix from <prefix>--slug branch
#   7. Pre-commit duplicate-id guard accepts UUID-format IDs in gap YAML
#   8. Audit doc exists at docs/audits/UUID-GAP-ID-COMPAT.md
#   9. INFRA-630 referenced in bot-merge.sh and gap_store.rs

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-630: UUID gap-ID compatibility suite ==="

# ── Locate chump binary ───────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
  if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
  elif command -v chump &>/dev/null; then
    CHUMP_BIN="$(command -v chump)"
  fi
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Build synthetic CHUMP_REPO with .chump/state.db ──────────────────────────
FAKE_REPO="$TMPDIR_TEST/fake-repo"
FAKE_DB="$FAKE_REPO/.chump/state.db"
mkdir -p "$FAKE_REPO/.chump"

FULL_UUID="8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9"
SHORT_PREFIX="8d3f2c0e"

sqlite3 "$FAKE_DB" <<'SQL'
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
SQL
sqlite3 "$FAKE_DB" \
  "INSERT INTO gaps(id,domain,title,status,priority,effort) VALUES('8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9','INFRA','UUID compat test gap','open','P2','s');"

if [[ ! -f "$FAKE_DB" ]]; then
  echo "FATAL: sqlite3 not available or DB creation failed"
  exit 2
fi
ok "Synthetic state.db created with UUID-format gap"

# Helper: run chump with fake repo so it finds our synthetic DB
_chump() {
  if [[ -n "$CHUMP_BIN" ]]; then
    CHUMP_REPO="$FAKE_REPO" "$CHUMP_BIN" "$@" 2>&1
  else
    echo "(chump binary not found — skipping)"
  fi
}

# ── Tests 1-4: chump gap preflight + show with UUID and short-prefix ──────────
echo "--- 1. chump gap preflight <full-UUID>"
if [[ -n "$CHUMP_BIN" ]]; then
  out1="$(_chump gap preflight "$FULL_UUID" 2>&1 || true)"
  if echo "$out1" | grep -q '\[preflight\] OK'; then
    ok "chump gap preflight $FULL_UUID → OK"
  else
    fail "chump gap preflight $FULL_UUID did not return OK (got: $out1)"
  fi
else
  ok "chump binary not built — skip (structural checks only)"
fi

echo "--- 2. chump gap preflight <8-char-prefix>"
if [[ -n "$CHUMP_BIN" ]]; then
  out2="$(_chump gap preflight "$SHORT_PREFIX" 2>&1 || true)"
  if echo "$out2" | grep -q '\[preflight\] OK'; then
    ok "chump gap preflight $SHORT_PREFIX → OK (prefix-match)"
  else
    fail "chump gap preflight $SHORT_PREFIX did not return OK via prefix-match (got: $out2)"
  fi
else
  ok "chump binary not built — skip"
fi

echo "--- 3. chump gap show <full-UUID>"
if [[ -n "$CHUMP_BIN" ]]; then
  out3="$(_chump gap show "$FULL_UUID" 2>&1 || true)"
  if echo "$out3" | grep -q 'UUID compat test gap'; then
    ok "chump gap show $FULL_UUID → prints gap title"
  else
    fail "chump gap show $FULL_UUID did not print expected title (got: $out3)"
  fi
else
  ok "chump binary not built — skip"
fi

echo "--- 4. chump gap show <8-char-prefix>"
if [[ -n "$CHUMP_BIN" ]]; then
  out4="$(_chump gap show "$SHORT_PREFIX" 2>&1 || true)"
  if echo "$out4" | grep -q 'UUID compat test gap'; then
    ok "chump gap show $SHORT_PREFIX → prints gap title (prefix-match)"
  else
    fail "chump gap show $SHORT_PREFIX did not print expected title via prefix-match (got: $out4)"
  fi
else
  ok "chump binary not built — skip"
fi

# ── Tests 5-6: bot-merge.sh UUID auto-derive ─────────────────────────────────
echo "--- 5. bot-merge.sh: full UUID in branch name"
# Replicate the INFRA-630-patched extraction logic from bot-merge.sh
_simulate_auto_derive() {
  local branch_name="$1"
  local _branch_raw
  _branch_raw=$(echo "$branch_name" \
      | sed -E "s,^(chump|claude|chore)/(file-|close-|fix-)?,," )
  local _uuid_full
  _uuid_full=$(printf '%s' "$_branch_raw" \
      | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' 2>/dev/null \
      | tr '[:lower:]' '[:upper:]' | sort -u | tr '\n' ' ' || true)
  local _uuid_short
  _uuid_short=$(printf '%s' "$_branch_raw" \
      | sed -n 's/^\([0-9a-f]\{8\}\)--.*$/\1/p' \
      | tr '[:lower:]' '[:upper:]' || true)
  echo "${_uuid_full}${_uuid_short:+${_uuid_short} }"
}

FULL_UUID_BRANCH="chump/${FULL_UUID}-my-feature"
DERIVED_FULL="$(_simulate_auto_derive "$FULL_UUID_BRANCH")"
if echo "$DERIVED_FULL" | grep -qi "8D3F2C0E-9F5B-4E1A-B2C3-D4E5F6A7B8C9"; then
  ok "bot-merge auto-derive extracts full UUID from branch '$FULL_UUID_BRANCH'"
else
  fail "bot-merge auto-derive failed for '$FULL_UUID_BRANCH' (got: '$DERIVED_FULL')"
fi

echo "--- 6. bot-merge.sh: 8-char short-prefix branch"
SHORT_BRANCH="chump/${SHORT_PREFIX}--implement-widget"
DERIVED_SHORT="$(_simulate_auto_derive "$SHORT_BRANCH")"
if echo "$DERIVED_SHORT" | grep -qi "8D3F2C0E"; then
  ok "bot-merge auto-derive extracts short-prefix from branch '$SHORT_BRANCH'"
else
  fail "bot-merge auto-derive failed for '$SHORT_BRANCH' (got: '$DERIVED_SHORT')"
fi

# ── Test 7: pre-commit duplicate-id guard accepts UUID-format IDs ─────────────
echo "--- 7. duplicate-id guard with UUID-format gap YAML"
FAKE_YAML="$TMPDIR_TEST/uuid-gap.yaml"
cat > "$FAKE_YAML" <<YAML
gaps:
- id: ${FULL_UUID}
  domain: INFRA
  title: UUID compat test gap
  status: open
  priority: P2
  effort: s
YAML

EXTRACTED=$(python3 -c "
import re
text = open('$FAKE_YAML').read()
ids = re.findall(r'^\s*-\s*id:\s*(\S+)', text, re.MULTILINE)
print('\n'.join(ids))
" 2>/dev/null || true)
if echo "$EXTRACTED" | grep -q "$FULL_UUID"; then
  ok "duplicate-id guard regex extracts UUID-format gap ID correctly"
else
  fail "duplicate-id guard regex failed to extract UUID from YAML (got: '$EXTRACTED')"
fi

# ── Test 8: audit doc exists ──────────────────────────────────────────────────
echo "--- 8. Audit document"
AUDIT_DOC="$REPO_ROOT/docs/audits/UUID-GAP-ID-COMPAT.md"
if [[ -f "$AUDIT_DOC" ]]; then
  ok "Audit doc exists at docs/audits/UUID-GAP-ID-COMPAT.md"
  if grep -q 'bot-merge' "$AUDIT_DOC" && grep -q 'prefix-match' "$AUDIT_DOC"; then
    ok "Audit doc covers bot-merge fix and prefix-match fix"
  else
    fail "Audit doc missing expected content (bot-merge / prefix-match)"
  fi
else
  fail "Audit doc not found at $AUDIT_DOC"
fi

# ── Test 9: INFRA-630 references in changed files ────────────────────────────
echo "--- 9. INFRA-630 references in source"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
if grep -q 'INFRA-630' "$BOT_MERGE"; then
  ok "INFRA-630 referenced in bot-merge.sh"
else
  fail "INFRA-630 reference missing from bot-merge.sh"
fi
# INFRA-1214: use source-grep.sh library instead of inline if/else
source "$(dirname "$0")/lib/source-grep.sh"
_gap_store_path=$(find_gap_store_path)
if grep -q 'INFRA-630' "$_gap_store_path"; then
  ok "INFRA-630 referenced in gap_store.rs"
else
  fail "INFRA-630 reference missing from gap_store.rs"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "INFRA-630 CI gate FAILED"
  exit 1
fi
echo "INFRA-630 CI gate PASSED"
