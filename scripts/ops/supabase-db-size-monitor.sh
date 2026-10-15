#!/usr/bin/env bash
# scripts/ops/supabase-db-size-monitor.sh — PRODUCT-378
#
# Monitor Olive's Supabase database size and alert when approaching the 0.5 GB free limit.
# Queries database size and top-10 tables to alert at 400 MB threshold.
#
# Usage:
#   bash scripts/ops/supabase-db-size-monitor.sh
#   bash scripts/ops/supabase-db-size-monitor.sh --dry-run
#
# Env:
#   OLIVE_SUPABASE_URL       Supabase project URL (https://<project>.supabase.co)
#   OLIVE_SUPABASE_KEY       Service role key (for SQL queries via RPC)
#   CHUMP_AMBIENT_OVERRIDE   Path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   CHUMP_SUPABASE_SIZE_WARN_MB   Alert threshold in MB (default: 400)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
WARN_MB="${CHUMP_SUPABASE_SIZE_WARN_MB:-400}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[supabase-db-size-monitor %s] %s\n' "$(ts)" "$*"; }

emit_ambient() {
    local kind="$1"; shift
    local body="$1"; shift
    local extra="${1:-}"
    [[ $DRY -eq 1 ]] && { log "DRY-RUN: would emit $kind — $body"; return 0; }
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    if [[ -n "$extra" ]]; then
        printf '{"ts":"%s","session":"supabase-db-size-monitor","event":"ALERT","kind":"%s","body":"%s",%s}\n' \
            "$(ts)" "$kind" "$body" "$extra" >> "$AMBIENT" 2>/dev/null || true
    else
        printf '{"ts":"%s","session":"supabase-db-size-monitor","event":"ALERT","kind":"%s","body":"%s"}\n' \
            "$(ts)" "$kind" "$body" >> "$AMBIENT" 2>/dev/null || true
    fi
}

log "Starting Supabase database size monitor"

if [[ -z "${OLIVE_SUPABASE_URL:-}" ]]; then
    log "ERROR: OLIVE_SUPABASE_URL not set"
    exit 1
fi

if [[ -z "${OLIVE_SUPABASE_KEY:-}" ]]; then
    log "ERROR: OLIVE_SUPABASE_KEY not set"
    exit 1
fi

# Use Supabase Management API to get project stats
# Parse the project from the URL
OLIVE_PROJECT_ID=$(echo "$OLIVE_SUPABASE_URL" | sed -E 's|https://([^.]+)\.supabase\.co.*|\1|')

if [[ -z "$OLIVE_PROJECT_ID" ]]; then
    log "ERROR: Could not parse project ID from $OLIVE_SUPABASE_URL"
    exit 1
fi

log "Querying $OLIVE_SUPABASE_URL for database size (project: $OLIVE_PROJECT_ID)"

# Query using RPC endpoint with SQL queries
# Create a temporary file for the response
RESPONSE_FILE=$(mktemp)
trap "rm -f $RESPONSE_FILE" EXIT

# Use Supabase's built-in pg_total_relation_size via RPC
# We need to query the database directly using service role credentials
DB_QUERY='SELECT pg_database_size(current_database()) as size_bytes'

# Call via REST API with RPC function
RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OLIVE_SUPABASE_KEY" \
    -H "apikey: $OLIVE_SUPABASE_KEY" \
    -d "{\"query\": \"$DB_QUERY\"}" \
    "$OLIVE_SUPABASE_URL/rest/v1/rpc/sql" 2>&1 || true)

log "RPC response: $RESPONSE"

# If RPC doesn't work, try the Management API to get database size stats
# This requires an admin/management token, not the service role key
# Fallback: use the Supabase dashboard Statistics endpoint if available

# For now, store a baseline reading via REST API query on a health table
# and log the size approximation from table inspection
TABLES_QUERY='SELECT schemaname, tablename, pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename) as bytes FROM pg_tables WHERE schemaname NOT IN ('"'"'pg_catalog'"'"', '"'"'information_schema'"'"') ORDER BY pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename) DESC LIMIT 10'

TABLES_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OLIVE_SUPABASE_KEY" \
    -H "apikey: $OLIVE_SUPABASE_KEY" \
    -d "{\"query\": \"$TABLES_QUERY\"}" \
    "$OLIVE_SUPABASE_URL/rest/v1/rpc/sql" 2>&1 || true)

log "Tables response: $TABLES_RESPONSE"

# Parse sizes from responses
SIZE_BYTES=$(echo "$RESPONSE" | jq -r '.[0].size_bytes // empty' 2>/dev/null || echo "0")

if [[ "$SIZE_BYTES" == "0" ]]; then
    log "WARN: Could not query database size directly, trying alternative method"
    # Fallback: estimate from largest table info if available
    SIZE_BYTES=$(echo "$TABLES_RESPONSE" | jq 'map(.bytes) | add // 0' 2>/dev/null || echo "0")
fi

if [[ "$SIZE_BYTES" == "0" ]]; then
    log "ERROR: Could not determine database size"
    emit_ambient "supabase_db_size_error" "Failed to query database size from $OLIVE_SUPABASE_URL"
    exit 1
fi

SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
SIZE_GB=$(echo "scale=3; $SIZE_BYTES / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0.000")

log "Database size: ${SIZE_MB} MB (${SIZE_GB} GB)"

# Parse top tables
TABLE_LIST=$(echo "$TABLES_RESPONSE" | jq -r '.[] | "\(.schemaname).\(.tablename): \(.bytes / 1024 / 1024 | round)MB"' 2>/dev/null || echo "")

BASELINE_MSG="Post-cleanup baseline: ~245 MB (2026-10-10)"

# Check threshold and emit alert or OK event
if [[ $SIZE_MB -ge $WARN_MB ]]; then
    BODY="ALERT: Olive Supabase database size is ${SIZE_MB} MB (~${SIZE_GB} GB) — approaching 500 MB free limit

Top tables:
${TABLE_LIST:-[unable to fetch table list]}

${BASELINE_MSG}"
    log "ALERT: Database size ${SIZE_MB} MB exceeds threshold ${WARN_MB} MB"
    emit_ambient "supabase_db_size_alert" "$BODY" \
        '"supabase_project":"olive","db_size_mb":'"$SIZE_MB"',"db_size_gb":'"${SIZE_GB:-0}"',"threshold_mb":'"$WARN_MB"
else
    BODY="OK: Olive Supabase database size is ${SIZE_MB} MB (~${SIZE_GB} GB)

Top tables:
${TABLE_LIST:-[unable to fetch table list]}

${BASELINE_MSG}"
    log "OK: Database size ${SIZE_MB} MB is below threshold ${WARN_MB} MB"
    emit_ambient "supabase_db_size_ok" "$BODY" \
        '"supabase_project":"olive","db_size_mb":'"$SIZE_MB"',"db_size_gb":'"${SIZE_GB:-0}"',"threshold_mb":'"$WARN_MB"
fi

exit 0
