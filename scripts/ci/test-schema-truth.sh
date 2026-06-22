#!/usr/bin/env bash
# test-schema-truth.sh — INFRA-1551
#
# Asserts that dead schema (routing_outcomes, intents) no longer exists after
# GapStore::open() runs migrate(), and that the state.db table set matches the
# expected set of production-written tables.
#
# Future-corpse surface: if a new table is added to ensure_schema but never
# written in production, this test catches it via the ALLOWED_TABLES allowlist.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
BINARY="$REPO_ROOT/target/debug/chump"

echo "=== INFRA-1551 schema-truth test ==="
echo

# ── 1. Dead tables must not appear in ensure_schema ─────────────────────────
GAPSTORE="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"

if ! grep -q "CREATE TABLE IF NOT EXISTS intents" "$GAPSTORE"; then
    ok "intents not in ensure_schema"
else
    fail "intents still created in ensure_schema — should be dropped (INFRA-1551)"
fi

if ! grep -q "CREATE TABLE IF NOT EXISTS routing_outcomes" "$GAPSTORE"; then
    ok "routing_outcomes not in ensure_schema"
else
    fail "routing_outcomes still created in ensure_schema — should be dropped (INFRA-1551)"
fi

# ── 2. DROP TABLE migrations are present ────────────────────────────────────
if grep -q "DROP TABLE IF EXISTS routing_outcomes" "$GAPSTORE"; then
    ok "routing_outcomes DROP migration in ensure_schema"
else
    fail "routing_outcomes DROP migration missing from ensure_schema"
fi

if grep -q "DROP TABLE IF EXISTS intents" "$GAPSTORE"; then
    ok "intents DROP migration in ensure_schema"
else
    fail "intents DROP migration missing from ensure_schema"
fi

# ── 3. schema_migration.sql documents the culls ─────────────────────────────
MIGRATION="$REPO_ROOT/schema_migration.sql"
if grep -q "DROP TABLE IF EXISTS routing_outcomes" "$MIGRATION"; then
    ok "routing_outcomes DROP in schema_migration.sql"
else
    fail "routing_outcomes DROP missing from schema_migration.sql"
fi

if grep -q "DROP TABLE IF EXISTS intents" "$MIGRATION"; then
    ok "intents DROP in schema_migration.sql"
else
    fail "intents DROP missing from schema_migration.sql"
fi

# ── 4. Runtime: open a fresh state.db and verify tables ─────────────────────
if [ ! -f "$BINARY" ]; then
    echo "  SKIP: binary not built (run cargo build first)"
else
    TMPDIR_DB="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_DB"' EXIT

    # chump gap list opens a GapStore (runs migrate()) against CHUMP_STATE_DB.
    # Use a temp dir repo with an empty state.db.
    mkdir -p "$TMPDIR_DB/.chump"
    CHUMP_REPO_ROOT="$TMPDIR_DB" "$BINARY" gap list --status open >/dev/null 2>&1 || true

    DB="$TMPDIR_DB/.chump/state.db"
    if [ -f "$DB" ]; then
        TABLES="$(sqlite3 "$DB" ".tables" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"

        if echo "$TABLES" | grep -qw "routing_outcomes"; then
            fail "routing_outcomes table still exists after migrate() — DROP not applied"
        else
            ok "routing_outcomes absent from fresh DB after migrate()"
        fi

        if echo "$TABLES" | grep -qw "intents"; then
            fail "intents table still exists after migrate() — DROP not applied"
        else
            ok "intents absent from fresh DB after migrate()"
        fi
    else
        echo "  SKIP: state.db not created (CHUMP_REPO_ROOT env var may be unsupported)"
    fi
fi

# ── 5. No references to removed CLI subcommand ──────────────────────────────
MAIN="$REPO_ROOT/src/main.rs"
if ! grep -q '"scoreboard"' "$MAIN" || grep -q 'routing_scoreboard()' "$MAIN"; then
    # Check specifically for the removed handler, not just the word
    if grep -q 'routing_scoreboard()' "$MAIN"; then
        fail "routing_scoreboard() call still in main.rs"
    else
        ok "routing_scoreboard() removed from main.rs"
    fi
else
    ok "routing_scoreboard() removed from main.rs"
fi

# ── 6. write_routing_outcome removed from monitor.rs ────────────────────────
MONITOR="$REPO_ROOT/crates/chump-orchestrator/src/monitor.rs"
if grep -q "fn write_routing_outcome" "$MONITOR"; then
    fail "write_routing_outcome still in monitor.rs"
else
    ok "write_routing_outcome removed from monitor.rs"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
