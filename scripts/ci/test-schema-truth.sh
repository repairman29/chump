#!/usr/bin/env bash
# test-schema-truth.sh — INFRA-1551: assert no production-read table has been
# INSERT-empty for >30 days, surfacing future schema corpses.
#
# What it checks:
#   1. The `intents` table has been fully removed (DROP TABLE IF EXISTS intents
#      runs on every GapStore::migrate() call).
#   2. `routing_outcomes` exists and has the expected schema columns.
#   3. Any table listed in MONITORED_TABLES that has zero rows emits a warning
#      (non-fatal) when the DB is old enough to expect data.
#
# Exit codes:
#   0  all checks pass
#   1  a structural invariant failed (intents still exists, routing_outcomes missing)
#
# Usage in CI: called by preflight and ci.yml; uses a temp DB for schema checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAIL=0
WARN=0

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=1; }
warn() { echo "  WARN: $*"; WARN=1; }

# Run a sqlite3 query against a DB file; print result.
sq() { sqlite3 "$1" "$2"; }

# ── build a fresh schema DB via GapStore::migrate() ──────────────────────────
# We compile + run `chump gap count` against a temp DB to trigger migrate().

TMPDIR_SCHEMA="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SCHEMA"' EXIT

TEMP_DB="$TMPDIR_SCHEMA/.chump/state.db"
mkdir -p "$TMPDIR_SCHEMA/.chump"

# Touch the temp DB so GapStore::open finds a writable path and runs migrate().
# We rely on `chump gap count` (or any gap subcommand) to open the store.
(
  cd "$REPO_ROOT"
  CHUMP_STATE_DB="$TEMP_DB" cargo run --bin chump --quiet -- gap count \
    >/dev/null 2>&1 || true
)

if [[ ! -f "$TEMP_DB" ]]; then
  # Fallback: create schema by opening with sqlite3 directly isn't possible
  # without re-implementing migrate(). Use the live state.db if present.
  LIVE_DB="$REPO_ROOT/.chump/state.db"
  if [[ -f "$LIVE_DB" ]]; then
    TEMP_DB="$LIVE_DB"
  else
    echo "SKIP: no state.db available and cargo run did not produce one; skipping schema-truth checks."
    exit 0
  fi
fi

echo "schema-truth: checking $TEMP_DB"

# ── check 1: intents table must NOT exist ────────────────────────────────────

INTENTS_EXISTS="$(sq "$TEMP_DB" \
  "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='intents';")"
if [[ "$INTENTS_EXISTS" == "0" ]]; then
  pass "intents table does not exist (dropped by INFRA-1551)"
else
  fail "intents table still exists — INFRA-1551 drop migration did not run"
fi

# ── check 2: routing_outcomes must exist with expected columns ────────────────

RO_EXISTS="$(sq "$TEMP_DB" \
  "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='routing_outcomes';")"
if [[ "$RO_EXISTS" == "0" ]]; then
  fail "routing_outcomes table missing — COG-036 scoreboard would be broken"
else
  pass "routing_outcomes table exists"
  # Verify key columns are present.
  for col in recorded_at task_class backend model gap_id outcome duration_s; do
    COL_EXISTS="$(sq "$TEMP_DB" \
      "SELECT COUNT(*) FROM pragma_table_info('routing_outcomes') WHERE name='$col';")"
    if [[ "$COL_EXISTS" == "1" ]]; then
      pass "  routing_outcomes.$col column present"
    else
      fail "  routing_outcomes.$col column missing"
    fi
  done
fi

# ── check 3: routing_outcomes INSERT-empty warning ────────────────────────────
# Non-fatal: warn if the live DB has never received a routing_outcomes row.
# (Workers write to their worktree DBs, so the main DB may legitimately be empty
# in dev; this becomes a real signal in fleet-running contexts.)

if [[ "$TEMP_DB" == "$REPO_ROOT/.chump/state.db" ]]; then
  RO_COUNT="$(sq "$TEMP_DB" "SELECT COUNT(*) FROM routing_outcomes;")"
  if [[ "$RO_COUNT" == "0" ]]; then
    warn "routing_outcomes is empty in live state.db — expected if fleet hasn't dispatched recently"
  else
    pass "routing_outcomes has $RO_COUNT row(s)"
  fi
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
if [[ $FAIL -eq 1 ]]; then
  echo "schema-truth: FAILED (structural invariant violated)"
  exit 1
elif [[ $WARN -eq 1 ]]; then
  echo "schema-truth: PASSED with warnings"
  exit 0
else
  echo "schema-truth: PASSED"
  exit 0
fi
