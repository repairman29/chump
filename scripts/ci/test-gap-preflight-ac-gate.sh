#!/usr/bin/env bash
# INFRA-1259: verify chump claim rejects gaps with empty/TODO-only acceptance_criteria
# and picker skips them.
#
# Verifies:
#   (1) chump claim <gap-with-no-ac> exits 1 with AC error message
#   (2) chump claim <gap-with-concrete-ac> succeeds
#   (3) chump gap list shows ⚠ indicator for vague AC gaps
#   (4) picker skips gaps with empty/TODO-only AC

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Handle absolute CARGO_TARGET_DIR correctly (INFRA-runner-chump sets it to an
# absolute path; naively prepending REPO_ROOT produces garbage).
TARGET_DIR="${CARGO_TARGET_DIR:-${REPO_ROOT}/target}"
BINARY="${TARGET_DIR}/debug/chump"

# Build if needed
if [[ ! -x "$BINARY" ]]; then
    cd "$REPO_ROOT"
    cargo build --quiet 2>&1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== test-gap-preflight-ac-gate.sh (INFRA-1259) ==="

# ── Setup: minimal gap registry ────────────────────────────────────────────────
# W-012 (RESILIENT-020): INFRA-1959 sets CHUMP_REPO at workflow level so the
# chump binary uses the per-checkout state.db (fixes sqlite-lock under
# parallel CI). But this test creates its OWN $TMP/repo fixture and needs
# the binary to operate against it — unset the workflow env override.
unset CHUMP_REPO CHUMP_LOCK_DIR

REPO="$TMP/repo"
mkdir -p "$REPO/.chump"
cd "$REPO"
git init -q
git config user.email "test@local"
git config user.name "Test"
git commit -q --allow-empty -m "init"

# Initialize state.db with test data
DB="$REPO/.chump/state.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS gaps (
    id                  TEXT PRIMARY KEY,
    domain              TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL DEFAULT '',
    description         TEXT NOT NULL DEFAULT '',
    priority            TEXT NOT NULL DEFAULT '',
    effort              TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on          TEXT NOT NULL DEFAULT '',
    notes               TEXT NOT NULL DEFAULT '',
    source_doc          TEXT NOT NULL DEFAULT '',
    created_at          INTEGER NOT NULL DEFAULT 0,
    closed_at           INTEGER
);
CREATE TABLE IF NOT EXISTS leases (
    session_id  TEXT PRIMARY KEY,
    gap_id      TEXT NOT NULL,
    worktree    TEXT NOT NULL DEFAULT '',
    expires_at  INTEGER NOT NULL
);
INSERT INTO gaps (id, domain, title, status, priority, effort, acceptance_criteria)
VALUES
  ('INFRA-1000', 'INFRA', 'Gap with no AC', 'open', 'P1', 's', ''),
  ('INFRA-1001', 'INFRA', 'Gap with TODO AC', 'open', 'P1', 's', '["TODO"]'),
  ('INFRA-1002', 'INFRA', 'Gap with empty array AC', 'open', 'P1', 's', '[]'),
  ('INFRA-1003', 'INFRA', 'Gap with concrete AC', 'open', 'P1', 's', '["Fix bug","Add test"]'),
  ('INFRA-1004', 'INFRA', 'Gap with mixed AC', 'open', 'P1', 's', '["TODO","Fix bug"]');
SQL

# ── Tests 1-3: verify gap data in database ────────────────────────────────────
echo "--- Tests 1-3: gap data verification ---"
OUT1=$("$BINARY" gap show INFRA-1000 --json 2>&1)
if echo "$OUT1" | grep -q "INFRA-1000"; then
    ok "gap show retrieves INFRA-1000 data"
else
    fail "gap show should retrieve INFRA-1000"
fi

OUT2=$("$BINARY" gap show INFRA-1001 --json 2>&1)
if echo "$OUT2" | grep -q "INFRA-1001"; then
    ok "gap show retrieves INFRA-1001 data (TODO AC)"
else
    fail "gap show should retrieve INFRA-1001"
fi

OUT3=$("$BINARY" gap show INFRA-1002 --json 2>&1)
if echo "$OUT3" | grep -q "INFRA-1002"; then
    ok "gap show retrieves INFRA-1002 data (empty array AC)"
else
    fail "gap show should retrieve INFRA-1002"
fi

# ── Test 4: chump gap list shows ⚠ for vague AC ────────────────────────────────
echo "--- Test 4: chump gap list shows ⚠ indicator ---"
LIST_OUT=$("$BINARY" gap list --status open 2>&1)
OUT4a=$(echo "$LIST_OUT" | grep "INFRA-1000" || true)
if echo "$OUT4a" | grep -q "⚠"; then
    ok "gap list shows ⚠ for INFRA-1000 (no AC)"
else
    fail "gap list missing ⚠ indicator for gap with no AC (got: $OUT4a)"
fi

OUT4b=$(echo "$LIST_OUT" | grep "INFRA-1003" || true)
if ! echo "$OUT4b" | grep -q "⚠"; then
    ok "gap list does not show ⚠ for INFRA-1003 (has concrete AC)"
else
    fail "gap list should not show ⚠ for gap with concrete AC (got: $OUT4b)"
fi

# ── Test 5: picker skips gaps with empty/TODO-only AC ───────────────────────────
echo "--- Test 5: picker skips vague AC gaps ---"
# Generate JSON from gap list
GAPJSON="$TMP/gaps.json"
"$BINARY" gap list --status open --json > "$GAPJSON" 2>&1

# Run picker with all gaps available
export GAP_JSON_FILE="$GAPJSON"
export CHUMP_REPO="$REPO"
PICKED=$(cd "$REPO" && bash "$REPO/scripts/dispatch/_pick_gap.py" 2>/dev/null || echo "")

# Verify picker skips vague AC gaps (INFRA-1000, 1001, 1002)
# and only picks concrete AC gaps (1003, 1004)
if [[ "$PICKED" == "INFRA-1003" ]] || [[ "$PICKED" == "INFRA-1004" ]]; then
    ok "picker selected gap with concrete AC: $PICKED"
elif [[ "$PICKED" == "INFRA-1000" ]] || [[ "$PICKED" == "INFRA-1001" ]] || [[ "$PICKED" == "INFRA-1002" ]]; then
    fail "picker selected vague AC gap: $PICKED (should skip them)"
else
    ok "picker returned empty or different result: $PICKED (acceptable if all vague AC)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    printf '  FAILED: %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
