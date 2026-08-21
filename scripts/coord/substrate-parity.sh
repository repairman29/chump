#!/usr/bin/env bash
# substrate-parity.sh — INFRA-3618 Substrate S1/S2
#
# Reports row-count + per-field drift between the canonical local
# .chump/state.db `gaps` table and the shared `shared_gaps` table on the
# self-hosted PostgREST substrate (CHUMP_TEAM_URL). This is the parity
# gauge S2 gates on (>= 99.x% for K days before reads are allowed to flip
# to Postgres in S3) — it does NOT write anything; read-only in both
# directions.
#
# Usage:
#   bash scripts/coord/substrate-parity.sh [--json] [--repo PATH]
#
# Requires: sqlite3, curl, jq. Requires CHUMP_TEAM_URL + CHUMP_TEAM_API_KEY
# in the environment (same vars the chump-team Rust client reads). If
# either is unset, exits 2 with a clear message rather than a confusing
# curl failure.
#
# Exit codes:
#   0  parity OK (no drift, or only fields not shadow-written yet)
#   1  drift found in shadowed fields (status/priority/effort/closed_pr)
#   2  environment not ready (missing CHUMP_TEAM_URL/API_KEY, missing tools)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
WANT_JSON=0
prev=""
for arg in "$@"; do
    case "$arg" in
        --json) WANT_JSON=1 ;;
        --repo) ;;
    esac
    case "$prev" in
        --repo) REPO_ROOT="$arg" ;;
    esac
    prev="$arg"
done

STATE_DB="$REPO_ROOT/.chump/state.db"

for tool in sqlite3 curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "substrate-parity: missing required tool '$tool'" >&2
        exit 2
    fi
done

if [[ -z "${CHUMP_TEAM_URL:-}" || -z "${CHUMP_TEAM_API_KEY:-}" ]]; then
    echo "substrate-parity: CHUMP_TEAM_URL and CHUMP_TEAM_API_KEY must both be set" >&2
    echo "  (same env the chump-team Rust client + CHUMP_STORE_SHADOW path read)" >&2
    exit 2
fi

if [[ ! -f "$STATE_DB" ]]; then
    echo "substrate-parity: no local state.db at $STATE_DB" >&2
    exit 2
fi

# ── local side ──────────────────────────────────────────────────────────
LOCAL_COUNT=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps;")
LOCAL_ROWS=$(sqlite3 -json "$STATE_DB" \
    "SELECT id, status, priority, effort, closed_pr FROM gaps ORDER BY id;")

# ── shared side ─────────────────────────────────────────────────────────
SHARED_JSON=$(curl -sS \
    -H "apikey: $CHUMP_TEAM_API_KEY" \
    -H "Authorization: Bearer $CHUMP_TEAM_API_KEY" \
    "$CHUMP_TEAM_URL/rest/v1/shared_gaps?select=id,status,priority,effort,closed_pr" \
    2>/dev/null || echo "[]")
if ! echo "$SHARED_JSON" | jq -e . >/dev/null 2>&1; then
    echo "substrate-parity: shared_gaps fetch did not return valid JSON — is PostgREST up at $CHUMP_TEAM_URL?" >&2
    exit 2
fi
SHARED_COUNT=$(echo "$SHARED_JSON" | jq 'length')

# ── local status string -> shared enum, mirrors src/shadow.rs map_status ──
map_status() {
    case "$1" in
        open) echo "open" ;;
        done|shipped) echo "shipped" ;;
        superseded|wontfix|wont_fix|closed|closed_not_a_bug|already_satisfied) echo "superseded" ;;
        blocked) echo "blocked" ;;
        *) echo "claimed" ;;
    esac
}

DRIFT_COUNT=0
MISSING_COUNT=0
FIELD_DRIFT_JSON="[]"

while IFS=$'\t' read -r id status priority effort closed_pr; do
    [[ -z "$id" ]] && continue
    shared_row=$(echo "$SHARED_JSON" | jq -c --arg id "$id" '.[] | select(.id == $id)')
    if [[ -z "$shared_row" ]]; then
        MISSING_COUNT=$((MISSING_COUNT + 1))
        continue
    fi
    expected_status=$(map_status "$status")
    shared_status=$(echo "$shared_row" | jq -r '.status')
    shared_priority=$(echo "$shared_row" | jq -r '.priority')
    shared_effort=$(echo "$shared_row" | jq -r '.effort')
    shared_closed_pr=$(echo "$shared_row" | jq -r '.closed_pr // "null"')
    local_closed_pr="${closed_pr:-null}"

    row_drift=0
    [[ "$expected_status" != "$shared_status" ]] && row_drift=1
    [[ "$priority" != "$shared_priority" ]] && row_drift=1
    [[ "$effort" != "$shared_effort" ]] && row_drift=1
    [[ "$local_closed_pr" != "$shared_closed_pr" ]] && row_drift=1

    if [[ "$row_drift" == "1" ]]; then
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        FIELD_DRIFT_JSON=$(echo "$FIELD_DRIFT_JSON" | jq \
            --arg id "$id" \
            --arg local_status "$status" --arg shared_status "$shared_status" \
            --arg local_priority "$priority" --arg shared_priority "$shared_priority" \
            --arg local_effort "$effort" --arg shared_effort "$shared_effort" \
            --arg local_closed_pr "$local_closed_pr" --arg shared_closed_pr "$shared_closed_pr" \
            '. + [{id: $id, local: {status: $local_status, priority: $local_priority, effort: $local_effort, closed_pr: $local_closed_pr}, shared: {status: $shared_status, priority: $shared_priority, effort: $shared_effort, closed_pr: $shared_closed_pr}}]')
    fi
done < <(echo "$LOCAL_ROWS" | jq -r '.[] | [.id, .status, .priority, .effort, (.closed_pr // "null")] | @tsv')

PARITY_PCT="100.00"
if [[ "$LOCAL_COUNT" -gt 0 ]]; then
    PARITY_PCT=$(awk -v total="$LOCAL_COUNT" -v bad="$((DRIFT_COUNT + MISSING_COUNT))" \
        'BEGIN { printf "%.2f", (total - bad) / total * 100 }')
fi

if [[ "$WANT_JSON" == "1" ]]; then
    jq -n \
        --argjson local_count "$LOCAL_COUNT" \
        --argjson shared_count "$SHARED_COUNT" \
        --argjson missing_count "$MISSING_COUNT" \
        --argjson drift_count "$DRIFT_COUNT" \
        --arg parity_pct "$PARITY_PCT" \
        --argjson drift "$FIELD_DRIFT_JSON" \
        '{local_count: $local_count, shared_count: $shared_count, missing_in_shared: $missing_count, field_drift_count: $drift_count, parity_pct: ($parity_pct | tonumber), drift: $drift}'
else
    echo "substrate-parity: local=$LOCAL_COUNT shared=$SHARED_COUNT missing_in_shared=$MISSING_COUNT field_drift=$DRIFT_COUNT parity=${PARITY_PCT}%"
    if [[ "$DRIFT_COUNT" -gt 0 ]]; then
        echo "$FIELD_DRIFT_JSON" | jq -r '.[] | "  DRIFT \(.id): local=\(.local) shared=\(.shared)"'
    fi
fi

if [[ "$DRIFT_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
