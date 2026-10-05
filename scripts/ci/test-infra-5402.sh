#!/usr/bin/env bash
# test-infra-5402.sh — INFRA-5402 (INFRA-3631 slice) tests.
#
# Verifies the shared-fleet queue schema is applied via Rust init_schema
# (crates/chump-gap-store/src/backend/postgres.rs::PostgresBackend::
# init_shared_schema) rather than piping supabase/migrations/*.sql through
# psql, and that install-gap-substrate.sh's apply_schema step invokes it.
#
# A live Postgres round-trip is covered by the feature-gated
# `#[cfg(feature = "postgres-backend")]` test in
# crates/chump-gap-store/src/backend/postgres.rs (requires
# CHUMP_TEST_POSTGRES_URL) — this script is the CI-reachable smoke layer:
# static checks that don't need a database.

set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PG_RS="$REPO_ROOT/crates/chump-gap-store/src/backend/postgres.rs"
SUBSTRATE_SH="$REPO_ROOT/scripts/setup/install-gap-substrate.sh"
BIN_RS="$REPO_ROOT/crates/chump-gap-store/src/bin/chump-gap-substrate-init.rs"

echo "=== INFRA-5402 tests ==="
echo

# ── Test 1: init_shared_schema exists and covers all 3 required tables ─────
echo "--- Test 1: init_shared_schema creates shared_gaps/shared_claims/worker_capabilities ---"
if grep -q "pub fn init_shared_schema" "$PG_RS"; then
    ok "Test 1a: init_shared_schema fn present"
else
    fail "Test 1a: init_shared_schema fn missing from postgres.rs"
fi
for tbl in shared_gaps shared_claims worker_capabilities; do
    if grep -q "CREATE TABLE IF NOT EXISTS $tbl" "$PG_RS"; then
        ok "Test 1b: CREATE TABLE IF NOT EXISTS $tbl present"
    else
        fail "Test 1b: CREATE TABLE IF NOT EXISTS $tbl missing"
    fi
done

# ── Test 2: the CAS guarantee (partial unique index) is present ────────────
echo "--- Test 2: shared_claims CAS partial-unique index ---"
if grep -q "shared_claims_active_unique" "$PG_RS" && grep -q "WHERE released_at IS NULL" "$PG_RS"; then
    ok "Test 2: shared_claims_active_unique partial unique index present"
else
    fail "Test 2: shared_claims CAS index missing or not partial"
fi

# ── Test 3: idempotency — every DDL statement is IF NOT EXISTS ─────────────
echo "--- Test 3: init_shared_schema statements are idempotent (re-run is a no-op) ---"
_sec="$(awk '/pub fn init_shared_schema/,/^    }$/' "$PG_RS")"
if echo "$_sec" | grep -q "CREATE TABLE" && ! echo "$_sec" | grep "CREATE TABLE" | grep -qv "IF NOT EXISTS"; then
    ok "Test 3a: every CREATE TABLE in init_shared_schema uses IF NOT EXISTS"
else
    fail "Test 3a: a CREATE TABLE in init_shared_schema is missing IF NOT EXISTS"
fi
if echo "$_sec" | grep -q "CREATE.*INDEX" && ! echo "$_sec" | grep "CREATE.*INDEX" | grep -qv "IF NOT EXISTS"; then
    ok "Test 3b: every CREATE INDEX in init_shared_schema uses IF NOT EXISTS"
else
    fail "Test 3b: a CREATE INDEX in init_shared_schema is missing IF NOT EXISTS"
fi

# ── Test 4: install-gap-substrate.sh invokes the Rust binary, not raw psql ──
echo "--- Test 4: apply_schema invokes chump-gap-substrate-init ---"
if grep -q "chump-gap-substrate-init" "$SUBSTRATE_SH"; then
    ok "Test 4a: install-gap-substrate.sh references chump-gap-substrate-init"
else
    fail "Test 4a: install-gap-substrate.sh does not reference chump-gap-substrate-init"
fi
if [[ -f "$BIN_RS" ]]; then
    ok "Test 4b: chump-gap-substrate-init.rs binary source exists"
else
    fail "Test 4b: chump-gap-substrate-init.rs binary source missing"
fi

# ── Test 5: bin target is properly feature-gated in Cargo.toml ─────────────
echo "--- Test 5: bin target requires postgres-backend feature ---"
if grep -A2 'name = "chump-gap-substrate-init"' "$REPO_ROOT/crates/chump-gap-store/Cargo.toml" \
     | grep -q 'required-features = \["postgres-backend"\]'; then
    ok "Test 5: chump-gap-substrate-init requires postgres-backend feature"
else
    fail "Test 5: chump-gap-substrate-init missing required-features gate"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
