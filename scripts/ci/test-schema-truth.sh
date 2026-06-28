#!/usr/bin/env bash
# INFRA-1551 (AC7): assert no production-read table in state.db is INSERT-empty
# in the Rust source. A table that only appears in SELECT statements (never in
# INSERT or "CREATE TABLE IF NOT EXISTS" as a write target) is a schema corpse.
#
# Detection strategy: scan Rust source for table names that appear in:
#   SELECT ... FROM <table>     → read
#   INSERT INTO <table>         → write
# Tables with reads but no writes are reported as corpses.
#
# Known write-only or DDL-only tables are excluded via ALLOWLIST below.
# Add a table here when it is intentionally read-only (e.g. a view or
# external-feed table), with a reason comment.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
SRC="$REPO_ROOT/src"
CRATES="$REPO_ROOT/crates"

# Tables that are legitimately read-only or have writes outside Rust source.
# Format: table_name  # reason
ALLOWLIST=(
    gap_dup_archive_audit   # write via record_dup_archive (has INSERT)
    gap_offline_bypass_audit # write via record_offline_bypass (has INSERT)
    gap_status_registry     # write via shell/chump CLI
    sqlite_master           # SQLite internal catalog
    sqlite_sequence         # SQLite internal autoincrement sequence
)

allowlist_contains() {
    local needle="$1"
    for entry in "${ALLOWLIST[@]}"; do
        if [[ "$entry" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# Collect all unique table names referenced in SELECT ... FROM <table> in Rust.
mapfile -t read_tables < <(
    grep -rh --include="*.rs" -E 'FROM\s+([a-z_]+)' "$SRC" "$CRATES" 2>/dev/null \
    | grep -oE 'FROM\s+[a-z_]+' \
    | awk '{print $2}' \
    | sort -u
)

# Collect all unique table names referenced in INSERT INTO <table> in Rust.
mapfile -t write_tables < <(
    grep -rh --include="*.rs" -E 'INSERT\s+(OR\s+\w+\s+)?INTO\s+([a-z_]+)' "$SRC" "$CRATES" 2>/dev/null \
    | grep -oE 'INTO\s+[a-z_]+' \
    | awk '{print $2}' \
    | sort -u
)

corpses=()
for tbl in "${read_tables[@]}"; do
    if allowlist_contains "$tbl"; then
        continue
    fi
    found_write=0
    for w in "${write_tables[@]}"; do
        if [[ "$w" == "$tbl" ]]; then
            found_write=1
            break
        fi
    done
    if [[ "$found_write" -eq 0 ]]; then
        corpses+=("$tbl")
    fi
done

if [[ "${#corpses[@]}" -eq 0 ]]; then
    echo "PASS: no read-only schema corpses found in Rust source"
    exit 0
fi

echo "FAIL: the following tables are SELECTed but never INSERTed in Rust source:"
for c in "${corpses[@]}"; do
    echo "  - $c"
done
echo ""
echo "Fix: either wire an INSERT path, drop the table, or add to ALLOWLIST with reason."
exit 1
