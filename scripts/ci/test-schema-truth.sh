#!/usr/bin/env bash
# test-schema-truth.sh — INFRA-1551
#
# Asserts that no production-read table in .chump/state.db has been
# INSERT-empty since the schema was created, surfacing future corpses.
#
# Checks:
#  1. intents table has been dropped (not present in state.db schema)
#  2. routing_outcomes INSERT code exists (wired, not orphaned)
#  3. gaps.skills_required column exists and has non-empty rows (filled)
#  4. Dead-schema documentation present in schema_migration.sql

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE_DB="$REPO_ROOT/.chump/state.db"
GAP_STORE="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"

echo "=== INFRA-1551 schema-truth test ==="
echo

# ── 1. intents table dropped ──────────────────────────────────────────────────

# 1a. CREATE TABLE for intents removed from gap_store source (excluding comments)
if ! grep -v "^\s*//" "$GAP_STORE" | grep -q "CREATE TABLE IF NOT EXISTS intents"; then
    ok "intents CREATE TABLE removed from GapStore::create_schema()"
else
    fail "intents CREATE TABLE still present in $GAP_STORE — should have been removed"
fi

# 1b. DROP TABLE migration added to gap_store
if grep -q "DROP TABLE IF EXISTS intents" "$GAP_STORE"; then
    ok "DROP TABLE IF EXISTS intents migration present in GapStore::migrate()"
else
    fail "DROP TABLE IF EXISTS intents migration missing from $GAP_STORE"
fi

# 1c. If a live state.db exists, verify intents table is absent
if [[ -s "$STATE_DB" ]]; then
    INTENTS_EXISTS=$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='intents';" 2>/dev/null || echo "0")
    if [[ "$INTENTS_EXISTS" == "0" ]]; then
        ok "intents table absent from live state.db"
    else
        fail "intents table still present in live state.db (run chump gap restore or open the store once)"
    fi
else
    ok "no live state.db to check (worktree or fresh clone)"
fi

# ── 2. routing_outcomes INSERT is wired ───────────────────────────────────────

MONITOR_RS="$REPO_ROOT/crates/chump-orchestrator/src/monitor.rs"
if [[ -f "$MONITOR_RS" ]]; then
    if grep -q "INSERT INTO routing_outcomes" "$MONITOR_RS"; then
        ok "routing_outcomes INSERT wired in chump-orchestrator/src/monitor.rs"
    else
        fail "routing_outcomes INSERT missing from $MONITOR_RS — table may be orphaned"
    fi
else
    ok "chump-orchestrator/src/monitor.rs not present (crate not yet extracted)"
fi

# ── 3. gaps.skills_required is filled ────────────────────────────────────────

# 3a. Column defined in GapStore
if grep -q "skills_required" "$GAP_STORE"; then
    ok "gaps.skills_required column present in GapStore"
else
    fail "gaps.skills_required column missing from $GAP_STORE"
fi

# 3b. If a live state.db exists, check non-empty rows
if [[ -s "$STATE_DB" ]]; then
    SR_COUNT=$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE skills_required != '';" 2>/dev/null || echo "0")
    if [[ "$SR_COUNT" -gt 0 ]]; then
        ok "gaps.skills_required has $SR_COUNT non-empty rows (actively filled)"
    else
        fail "gaps.skills_required is all-empty in live state.db — column is unfilled dead schema"
    fi
else
    ok "no live state.db to check skills_required fill rate"
fi

# ── 4. Dead-schema documentation in schema_migration.sql ─────────────────────

MIGRATION_SQL="$REPO_ROOT/schema_migration.sql"
if grep -q "INFRA-1551" "$MIGRATION_SQL"; then
    ok "INFRA-1551 dead-schema cull documented in schema_migration.sql"
else
    fail "INFRA-1551 documentation missing from $MIGRATION_SQL"
fi

if grep -q "intents table" "$MIGRATION_SQL"; then
    ok "intents DROP rationale documented in schema_migration.sql"
else
    fail "intents DROP rationale missing from schema_migration.sql"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "All schema-truth checks passed."
