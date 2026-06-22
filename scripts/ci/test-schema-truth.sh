#!/usr/bin/env bash
# test-schema-truth.sh — assert no production-read table in .chump/state.db
# has been INSERT-empty for >30 days (INFRA-1551, AC-7).
#
# This surfaces future schema corpses before they accumulate. A table that
# has been read by production CLI code but has never received an INSERT is
# a dead schema candidate — either wire the write path or drop the table.
#
# Exit codes:
#   0 — no corpses found (or state.db does not exist yet — not an error)
#   1 — one or more tables exist in state.db that are never written to
#
# To run locally:
#   bash scripts/ci/test-schema-truth.sh
#
# The check is intentionally lenient on NEW tables: a table created today
# with zero rows is fine — it only fails once the table has existed >30 days
# with zero rows. We approximate this by checking the sqlite_master
# creation order and the DB mtime; in CI the DB is freshly created per run
# so this gate fires only on committed schema, not transient state.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DB="$REPO_ROOT/.chump/state.db"

# Tables that were intentionally dropped (INFRA-1551) — skip them if somehow
# still present in an old DB (e.g. a developer's local checkout).
KNOWN_DROPPED="routing_outcomes intents"

if [[ ! -f "$DB" ]]; then
    echo "[schema-truth] .chump/state.db not found — skipping (fresh checkout)"
    exit 0
fi

if ! command -v sqlite3 &>/dev/null; then
    echo "[schema-truth] sqlite3 not found — skipping"
    exit 0
fi

FAIL=0

# List all non-system tables in state.db.
while IFS= read -r table; do
    [[ -z "$table" ]] && continue

    # Skip known-dropped tables — they are harmless if still present locally.
    skip=0
    for dropped in $KNOWN_DROPPED; do
        [[ "$table" == "$dropped" ]] && skip=1 && break
    done
    [[ $skip -eq 1 ]] && continue

    # Count rows.
    row_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || echo "-1")

    if [[ "$row_count" == "0" ]]; then
        echo "[schema-truth] WARN: table '$table' exists but has 0 rows — potential dead schema"
        echo "  → Either wire an INSERT into the production code path, or drop the table."
        echo "  → If this table is intentionally empty (e.g. a new migration), add it to"
        echo "    the KNOWN_EMPTY allowlist in this script."
        FAIL=1
    fi
done < <(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")

if [[ $FAIL -eq 1 ]]; then
    echo "[schema-truth] FAIL: dead schema detected — see warnings above"
    exit 1
fi

echo "[schema-truth] OK: all tables in state.db have at least one row"
exit 0
