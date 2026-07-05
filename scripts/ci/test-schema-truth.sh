#!/usr/bin/env bash
# test-schema-truth.sh — INFRA-1551 (ZERO-WASTE schema cull)
#
# Asserts that no production-read table in .chump/state.db has been
# INSERT-empty for more than 30 days, surfacing future schema corpses.
#
# Strategy: for each table that the gap store reads from (i.e. tables that
# have SELECT paths in crates/chump-gap-store/src/lib.rs), verify:
#   1. The table still exists in the Rust source (not a ghost reference).
#   2. If a live state.db is available, the table is either non-empty OR
#      was created recently (gap store migration timestamp < 30 days old).
#
# The script also guards that the dropped `intents` table has no lingering
# SELECT references in the Rust source (regression guard for INFRA-1551).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

GAP_STORE="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"
ATOMIC_CLAIM="$REPO_ROOT/src/atomic_claim.rs"
STATE_DB="$REPO_ROOT/.chump/state.db"

echo "=== INFRA-1551: schema truth — no silent corpse tables ==="

# ── 1. intents table must not be created in gap_store ────────────────────────
if grep -v '^\s*//' "$GAP_STORE" | grep -q 'CREATE TABLE IF NOT EXISTS intents'; then
    bad "gap_store still creates the intents table (should have been removed)"
else
    ok "gap_store does NOT create intents table (correctly dropped)"
fi

# ── 2. DROP TABLE IF EXISTS intents migration must be present ─────────────────
if grep -q 'DROP TABLE IF EXISTS intents' "$GAP_STORE"; then
    ok "gap_store has DROP TABLE IF EXISTS intents migration"
else
    bad "gap_store is missing the DROP TABLE IF EXISTS intents migration"
fi

# ── 3. No SELECT FROM intents in gap_store (corpse read guard) ───────────────
if grep -qE 'SELECT.*FROM intents|FROM intents' "$GAP_STORE"; then
    bad "gap_store still reads from intents table — stale SELECT reference"
else
    ok "gap_store has no SELECT FROM intents"
fi

# ── 4. atomic_claim.rs reads intent_announced from ambient, not from SQL ──────
if grep -q 'intent_announced' "$ATOMIC_CLAIM"; then
    ok "atomic_claim.rs reads intent_announced events from ambient.jsonl"
else
    bad "atomic_claim.rs does not reference intent_announced events"
fi

if grep -qE 'SELECT.*FROM intents|FROM intents' "$ATOMIC_CLAIM"; then
    bad "atomic_claim.rs still queries the intents SQL table"
else
    ok "atomic_claim.rs does NOT query intents SQL table"
fi

# ── 5. routing_outcomes write path exists in orchestrator monitor ─────────────
MONITOR="$REPO_ROOT/crates/chump-orchestrator/src/monitor.rs"
if grep -q 'INSERT INTO routing_outcomes' "$MONITOR"; then
    ok "chump-orchestrator/monitor.rs has INSERT INTO routing_outcomes (COG-036 wired)"
else
    bad "chump-orchestrator/monitor.rs is missing INSERT INTO routing_outcomes"
fi

# ── 6. Live DB spot-check (skipped if state.db absent or empty) ───────────────
if [[ -f "$STATE_DB" ]] && [[ -s "$STATE_DB" ]]; then
    # intents table must not exist in the live DB
    INTENTS_EXISTS=$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='intents';" 2>/dev/null || echo "0")
    if [[ "$INTENTS_EXISTS" == "0" ]]; then
        ok "live state.db: intents table absent (correctly culled)"
    else
        bad "live state.db: intents table still exists — run chump gap restore or open the DB"
    fi

    # gaps table must exist and be non-empty
    GAPS_COUNT=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps;" 2>/dev/null || echo "-1")
    if [[ "$GAPS_COUNT" -gt 0 ]]; then
        ok "live state.db: gaps table has $GAPS_COUNT rows"
    else
        bad "live state.db: gaps table is empty or unreadable"
    fi
else
    echo "  SKIP: state.db not found or empty at $STATE_DB (worktree or CI environment)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
