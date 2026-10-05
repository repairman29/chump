#!/usr/bin/env bash
# almanac_health.sh — INFRA-3715 (INFRA-3639 slice)
#
# Standalone health probe for the almanac binary + index: is the binary
# present/executable, does the index have any rows, and is it fresh enough
# to trust. Prints one JSON object to stdout and exits 0 when healthy,
# non-zero when not — so it can be dropped into a cron/launchd check or a
# curator's pre-flight without any state beyond the two paths below.
#
# Usage: scripts/health/almanac_health.sh [--json]
#   --json is accepted for symmetry with other chump health scripts but is
#   the default (and only) output format — the flag is a no-op.
#
# Env overrides (mirrors scripts/setup/refresh-almanac-binary.sh):
#   ALMANAC_BIN                      default: $HOME/Projects/almanac/target/release/almanac
#   ALMANAC_INDEX_DB                 default: $HOME/.almanac/indexes/chump.db
#   ALMANAC_HEALTH_STALE_THRESHOLD_S default: 86400 (24h)
#
# Exit codes:
#   0 — index_status == "ok"
#   1 — binary missing/not executable
#   2 — index_status == "empty"
#   3 — index_status == "stale"

set -uo pipefail

ALMANAC_BIN="${ALMANAC_BIN:-$HOME/Projects/almanac/target/release/almanac}"
ALMANAC_INDEX_DB="${ALMANAC_INDEX_DB:-$HOME/.almanac/indexes/chump.db}"
THRESHOLD_SECONDS="${ALMANAC_HEALTH_STALE_THRESHOLD_S:-86400}"

binary_present=false
if [[ -x "$ALMANAC_BIN" ]]; then
    binary_present=true
fi

last_indexed="null"
entry_count=0
db_readable=false

if [[ -f "$ALMANAC_INDEX_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
    if entry_count="$(sqlite3 "$ALMANAC_INDEX_DB" "SELECT COUNT(*) FROM files;" 2>/dev/null)"; then
        db_readable=true
        indexed_at="$(sqlite3 "$ALMANAC_INDEX_DB" "SELECT value FROM meta WHERE key='indexed_at';" 2>/dev/null || true)"
        if [[ -n "$indexed_at" ]]; then
            last_indexed="\"$indexed_at\""
        fi
    fi
fi
entry_count="${entry_count:-0}"
[[ "$entry_count" =~ ^[0-9]+$ ]] || entry_count=0

index_status="ok"
if [[ "$db_readable" != true || "$entry_count" -eq 0 ]]; then
    index_status="empty"
elif [[ "$last_indexed" != "null" ]]; then
    indexed_epoch="$(date -u -d "$(sqlite3 "$ALMANAC_INDEX_DB" "SELECT value FROM meta WHERE key='indexed_at';" 2>/dev/null)" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    age=$(( now_epoch - indexed_epoch ))
    if [[ "$indexed_epoch" -eq 0 || "$age" -gt "$THRESHOLD_SECONDS" ]]; then
        index_status="stale"
    fi
else
    # DB has rows but no indexed_at marker — treat as stale rather than ok,
    # since freshness can't be verified.
    index_status="stale"
fi

printf '{"binary_present":%s,"index_status":"%s","last_indexed":%s,"threshold_seconds":%d}\n' \
    "$binary_present" "$index_status" "$last_indexed" "$THRESHOLD_SECONDS"

if [[ "$binary_present" != true ]]; then
    exit 1
fi
case "$index_status" in
    empty) exit 2 ;;
    stale) exit 3 ;;
    *) exit 0 ;;
esac
