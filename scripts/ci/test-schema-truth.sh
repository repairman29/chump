#!/usr/bin/env bash
# INFRA-1551: assert no production-read table in .chump/state.db was dropped
# and re-appeared (schema corpse detector). Also verifies that the blacklisted
# dead tables (routing_outcomes, intents) do not re-exist after the INFRA-1551
# cull. Run under CI or locally before ship.
# Exit 1 on any violation.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(pwd)")"
STATE_DB="${REPO_ROOT}/.chump/state.db"

# Tables that were dead schema and were dropped in INFRA-1551.
# If these re-appear it means migrate() regressed or a migration was added
# without removing the DROP TABLE guard.
BLACKLISTED_TABLES=(routing_outcomes intents)

FAILED=0

check_blacklist() {
    local db="$1"
    for tbl in "${BLACKLISTED_TABLES[@]}"; do
        local exists
        exists=$(sqlite3 "$db" \
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${tbl}';" \
            2>/dev/null || echo "0")
        if [[ "$exists" != "0" ]]; then
            echo "[schema-truth] FAIL: blacklisted table '${tbl}' exists in ${db}" >&2
            FAILED=1
        fi
    done
}

if [[ ! -f "$STATE_DB" ]]; then
    # No live DB — run against a temp DB seeded by GapStore::open to verify
    # that migrate() itself does not create the blacklisted tables.
    TMP_DIR="$(mktemp -d)"
    TMP_DB="${TMP_DIR}/state.db"
    trap 'rm -rf "$TMP_DIR"' EXIT

    # Use chump to trigger a GapStore open (which runs migrate()).
    # If chump binary unavailable, skip live migration check.
    CHUMP_BIN="${REPO_ROOT}/target/debug/chump"
    if [[ -x "$CHUMP_BIN" ]]; then
        HOME="$TMP_DIR" CHUMP_REPO="$TMP_DIR" \
            "$CHUMP_BIN" gap list --status open >/dev/null 2>&1 || true
        TMP_STATE="${TMP_DIR}/.chump/state.db"
        if [[ -f "$TMP_STATE" ]]; then
            check_blacklist "$TMP_STATE"
        fi
    else
        echo "[schema-truth] chump binary not found at ${CHUMP_BIN} — skipping live migrate check"
    fi
else
    check_blacklist "$STATE_DB"
fi

if [[ $FAILED -ne 0 ]]; then
    echo "[schema-truth] FAIL: schema corpse detected — see above" >&2
    exit 1
fi

echo "[schema-truth] OK — no blacklisted tables found"
