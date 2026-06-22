#!/usr/bin/env bash
# scripts/ci/test-schema-truth.sh — INFRA-1551
#
# Assert that .chump/state.db contains no abandoned schema corpses:
#   1. The `intents` table must NOT exist (dropped in INFRA-1551).
#   2. Every table in the expected set DOES exist.
#   3. No table in the allow-listed-empty set causes a false alarm.
#
# "Schema corpse" = table exists in state.db schema but has zero rows AND
# no INSERT code exists anywhere in the codebase that targets it.
#
# This script is scoped to the tables we know are load-bearing. It does NOT
# attempt to scan Rust code for INSERT statements (too slow for CI). Instead:
#   - Tables known to be intentionally empty until an optional feature is
#     active (e.g. routing_outcomes — requires chump-orchestrator --watch)
#     are listed in ALLOWED_EMPTY below.
#   - Any table NOT in ALLOWED_EMPTY and NOT in EXPECTED_TABLES is flagged.
#
# Usage: bash scripts/ci/test-schema-truth.sh [--db <path>]
# Exit code: 0 = all checks pass; 1 = one or more assertions failed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0

check() {
    local desc="$1" result="$2"
    if [[ "$result" == "ok" ]]; then
        echo "  PASS  $desc"
        ((PASS++)) || true
    else
        echo "  FAIL  $desc — $result"
        ((FAIL++)) || true
    fi
}

if [[ ! -f "$DB" ]]; then
    echo "SKIP  state.db not found at $DB (fresh checkout — nothing to check)"
    exit 0
fi

echo "schema-truth: checking $DB"

# 1. intents table must be gone (INFRA-1551: dropped — never had INSERT code;
#    read_live_intents() reads ambient.jsonl events instead).
intents_count=$(sqlite3 "$DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='intents'")
if [[ "$intents_count" == "0" ]]; then
    check "intents table dropped" "ok"
else
    check "intents table dropped" "table still exists — run chump gap restore or open state.db with GapStore::open() to apply DROP migration"
fi

# 2. Core tables must exist.
EXPECTED_TABLES=(
    gaps
    gap_counters
    leases
    routing_outcomes
    outcomes
    repos
    gap_status_registry
    gap_dup_archive_audit
)
for tbl in "${EXPECTED_TABLES[@]}"; do
    cnt=$(sqlite3 "$DB" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$tbl'")
    if [[ "$cnt" == "1" ]]; then
        check "table '$tbl' exists" "ok"
    else
        check "table '$tbl' exists" "missing from schema"
    fi
done

# 3. Tables allowed to be empty (wired but feature-gated or rarely used).
#    routing_outcomes: INSERT path lives in chump-orchestrator --watch (COG-036/037);
#    empty when the orchestrator binary is not actively running.
ALLOWED_EMPTY=(routing_outcomes)

# 4. Flag any table NOT in EXPECTED_TABLES and NOT in ALLOWED_EMPTY.
ALL_TABLES=$(sqlite3 "$DB" \
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name" 2>/dev/null || true)
KNOWN=("${EXPECTED_TABLES[@]}" "${ALLOWED_EMPTY[@]}" sqlite_sequence gap_offline_bypass_audit)

for tbl in $ALL_TABLES; do
    known=0
    for k in "${KNOWN[@]}"; do
        [[ "$tbl" == "$k" ]] && known=1 && break
    done
    if [[ "$known" == "0" ]]; then
        row_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM \"$tbl\"" 2>/dev/null || echo "?")
        check "unknown table '$tbl' ($row_count rows)" \
            "not in expected set — either add it to EXPECTED_TABLES or file a gap to drop it"
    fi
done

echo ""
if [[ "$FAIL" -gt 0 ]]; then
    echo "schema-truth: $PASS passed, $FAIL FAILED"
    exit 1
else
    echo "schema-truth: $PASS passed"
    exit 0
fi
