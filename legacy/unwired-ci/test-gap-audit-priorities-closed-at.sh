#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# scripts/ci/test-gap-audit-priorities-closed-at.sh — INFRA-1682
#
# Regression guard for the "Invalid column type Text at index: 12, name:
# closed_at" crash. Discovered 2026-05-22 when ONE rogue row (INFRA-1390)
# with closed_at='2026-05-17 03:16:05' (TEXT instead of INTEGER) broke
# every audit-priorities query — bypassing META-046 fleet-health checks
# and the opus-curator's audit_gaps phase.
#
# The fix has two parts (both in crates/chump-gap-store/src/lib.rs):
#   1. SELECT-side: CASE WHEN typeof(closed_at)='integer' THEN closed_at
#      ELSE NULL END — defensive deserialization
#   2. Migration: heal existing bad rows on store open
#
# This test seeds a fixture state.db with a TEXT closed_at row and asserts
# `chump gap audit-priorities` exits 0 instead of crashing with the
# rusqlite type-mismatch error.
#
# Exit: 0 = fix intact, 1 = regression

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Find chump binary
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    else
        echo "FAIL INFRA-1682: chump binary not found"
        exit 1
    fi
fi

# Build an isolated fixture repo with a minimal state.db
FIXTURE_DIR="$(mktemp -d -t chump-infra-1682-XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
mkdir -p "$FIXTURE_DIR/.chump"

DB="$FIXTURE_DIR/.chump/state.db"

# Seed the minimal schema. We deliberately match the production gap table
# shape (subset of columns the audit query needs). The point of the test is
# not schema validation — it's that one TEXT row in closed_at doesn't crash
# the query.
sqlite3 "$DB" <<'SQL'
CREATE TABLE gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'P2',
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

-- Healthy open gap (no closed_at)
INSERT INTO gaps (id, title, priority, status, acceptance_criteria, created_at)
  VALUES ('TEST-001', 'healthy open P1', 'P1', 'open', '["AC1"]', 1779000000);

-- Healthy done gap with integer closed_at
INSERT INTO gaps (id, title, priority, status, closed_at, acceptance_criteria, created_at)
  VALUES ('TEST-002', 'healthy done with integer closed_at', 'P1', 'done', 1779100000,
          '["AC1"]', 1779000000);

-- The bug shape: done gap with TEXT closed_at. Pre-fix, this single row
-- crashes audit-priorities entirely with rusqlite type-mismatch.
INSERT INTO gaps (id, title, priority, status, closed_at, acceptance_criteria, created_at)
  VALUES ('TEST-003', 'bad TEXT closed_at — repro for INFRA-1682', 'P1', 'done',
          '2026-05-17 03:16:05', '["AC1"]', 1779000000);
SQL

# Confirm the bad row was inserted as TEXT (SQLite preserves storage class
# when the affinity is INTEGER but the inserted value is TEXT, mimicking
# the production rogue-row condition).
bad_type="$(sqlite3 "$DB" "SELECT typeof(closed_at) FROM gaps WHERE id='TEST-003'")"
if [[ "$bad_type" != "text" ]]; then
    echo "FAIL: fixture setup — expected TEST-003.closed_at typeof=text, got '$bad_type'"
    exit 1
fi

# Run audit-priorities against the fixture. PRE-fix: exits non-zero with
# "Invalid column type Text at index: 12, name: closed_at". POST-fix: exits
# 0 because (a) the SELECT CASE returns NULL for non-integer closed_at and
# (b) the migration coerced the TEXT row to integer.
cd "$FIXTURE_DIR"
output="$("$CHUMP_BIN" gap audit-priorities --json 2>&1)"
ec=$?

if [[ $ec -ne 0 ]]; then
    echo "FAIL INFRA-1682: chump gap audit-priorities exited $ec on a state.db with one TEXT closed_at row"
    echo "  output: $output"
    exit 1
fi

# Also assert the migration did its job: TEST-003.closed_at should now be
# INTEGER (the strftime('%s', '2026-05-17 03:16:05') coercion).
fixed_type="$(sqlite3 "$DB" "SELECT typeof(closed_at) FROM gaps WHERE id='TEST-003'")"
if [[ "$fixed_type" != "integer" ]]; then
    echo "FAIL INFRA-1682: migration did not heal TEST-003.closed_at (typeof=$fixed_type, want integer)"
    exit 1
fi

echo "OK INFRA-1682: audit-priorities tolerates TEXT closed_at + migration heals to integer"
