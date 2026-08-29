#!/usr/bin/env bash
# scripts/coord/lib/pr-rebase-circuit.sh — INFRA-1525
#
# Circuit breaker for pr-auto-rebase.sh (the "pr-rebase-daemon"). Today's
# signal: #2069/#2068/#2109/#2100/#2161 sat 15-21h old with persistent CI
# failures while the daemon kept rebasing them every cycle — ~5h/day of CI
# burn for zero convergence, because a rebase can't fix a genuine logic
# failure. This tracks each PR's last 5 recorded CI conclusions in
# .chump/pr-rebase-attempts.db and opens the circuit (skips the rebase) once
# the SAME failure name shows up in >=3 of the last 5 attempts within the
# last 12h. Resets automatically the moment the PR's head SHA changes (new
# commit = new chance).
#
# Sourced by scripts/coord/pr-auto-rebase.sh. Not meant to be run directly,
# but every function tolerates being called standalone for tests.
#
# Public functions:
#   circuit_db_init                          — create the sqlite db/table if missing
#   circuit_record_attempt PR SHA FAIL_NAME   — log one CI-failure observation
#   circuit_reset_if_new_sha PR SHA           — clear history when head SHA changed
#   circuit_check PR                          — prints "OPEN <fail_name> <count> <last_attempt>"
#                                                 or "CLOSED"; exit 0 always
#
# Env knobs:
#   CHUMP_REBASE_CIRCUIT_DB       — override db path (tests)
#   CHUMP_REBASE_CIRCUIT_THRESHOLD — consecutive-count threshold (default 3)
#   CHUMP_REBASE_CIRCUIT_WINDOW    — lookback attempt count (default 5)
#   CHUMP_REBASE_CIRCUIT_HOURS     — freshness window in hours (default 12)
#   CHUMP_REBASE_CIRCUIT_NOW       — ISO-8601 "now" override (tests)

_CIRCUIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CIRCUIT_REPO_ROOT="$(cd "$_CIRCUIT_LIB_DIR/../../.." && pwd)"

CIRCUIT_DB="${CHUMP_REBASE_CIRCUIT_DB:-$_CIRCUIT_REPO_ROOT/.chump/pr-rebase-attempts.db}"
CIRCUIT_THRESHOLD="${CHUMP_REBASE_CIRCUIT_THRESHOLD:-3}"
CIRCUIT_WINDOW="${CHUMP_REBASE_CIRCUIT_WINDOW:-5}"
CIRCUIT_HOURS="${CHUMP_REBASE_CIRCUIT_HOURS:-12}"

circuit_now() {
    if [[ -n "${CHUMP_REBASE_CIRCUIT_NOW:-}" ]]; then
        printf '%s' "$CHUMP_REBASE_CIRCUIT_NOW"
    else
        date -u +%Y-%m-%dT%H:%M:%SZ
    fi
}

circuit_db_init() {
    mkdir -p "$(dirname "$CIRCUIT_DB")"
    sqlite3 "$CIRCUIT_DB" "
        CREATE TABLE IF NOT EXISTS attempts (
            pr_number   INTEGER NOT NULL,
            sha         TEXT NOT NULL,
            conclusion  TEXT,
            fail_name   TEXT,
            attempted_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_attempts_pr ON attempts(pr_number, attempted_at);
    " 2>/dev/null
}

# circuit_reset_if_new_sha PR SHA
# If the most recent recorded attempt for PR has a different sha than the
# current head, the PR has moved (new commit) — clear history so it gets a
# clean slate (AC5).
circuit_reset_if_new_sha() {
    local pr="$1" sha="$2"
    circuit_db_init
    local last_sha
    last_sha="$(sqlite3 "$CIRCUIT_DB" "
        SELECT sha FROM attempts
        WHERE pr_number = $pr
        ORDER BY attempted_at DESC
        LIMIT 1;
    " 2>/dev/null)"
    if [[ -n "$last_sha" && "$last_sha" != "$sha" ]]; then
        sqlite3 "$CIRCUIT_DB" "DELETE FROM attempts WHERE pr_number = $pr;" 2>/dev/null
    fi
}

# circuit_record_attempt PR SHA FAIL_NAME [CONCLUSION]
circuit_record_attempt() {
    local pr="$1" sha="$2" fail_name="${3:-}" conclusion="${4:-FAILURE}"
    circuit_db_init
    local ts; ts="$(circuit_now)"
    # Escape single quotes defensively.
    fail_name="${fail_name//\'/\'\'}"
    sqlite3 "$CIRCUIT_DB" "
        INSERT INTO attempts (pr_number, sha, conclusion, fail_name, attempted_at)
        VALUES ($pr, '$sha', '$conclusion', '$fail_name', '$ts');
    " 2>/dev/null
    # Prune anything beyond the last CIRCUIT_WINDOW rows for this PR so the
    # table doesn't grow unbounded across the fleet's lifetime.
    sqlite3 "$CIRCUIT_DB" "
        DELETE FROM attempts
        WHERE pr_number = $pr
          AND attempted_at NOT IN (
              SELECT attempted_at FROM attempts
              WHERE pr_number = $pr
              ORDER BY attempted_at DESC
              LIMIT $CIRCUIT_WINDOW
          );
    " 2>/dev/null
}

# circuit_check PR — prints "OPEN <fail_name> <count> <last_attempt>" if the
# circuit should block a rebase, else "CLOSED".
circuit_check() {
    local pr="$1"
    circuit_db_init
    local now_epoch cutoff_epoch cutoff_iso
    now_epoch="$(python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('$(circuit_now)'.replace('Z','+00:00'))
    print(int(t.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    cutoff_epoch=$(( now_epoch - CIRCUIT_HOURS * 3600 ))
    cutoff_iso="$(python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp($cutoff_epoch, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || echo "1970-01-01T00:00:00Z")"

    local rows
    rows="$(sqlite3 -separator $'\t' "$CIRCUIT_DB" "
        SELECT fail_name, attempted_at FROM attempts
        WHERE pr_number = $pr AND fail_name != ''
        ORDER BY attempted_at DESC
        LIMIT $CIRCUIT_WINDOW;
    " 2>/dev/null)"

    if [[ -z "$rows" ]]; then
        echo "CLOSED"
        return 0
    fi

    # Tally fail_name occurrences; track most-recent attempted_at per name.
    local best_name="" best_count=0 best_last=""
    declare -A _counts=() _last=()
    while IFS=$'\t' read -r fname fts; do
        [[ -z "$fname" ]] && continue
        _counts["$fname"]=$(( ${_counts["$fname"]:-0} + 1 ))
        if [[ -z "${_last[$fname]:-}" || "$fts" > "${_last[$fname]}" ]]; then
            _last["$fname"]="$fts"
        fi
    done <<< "$rows"

    for fname in "${!_counts[@]}"; do
        if (( ${_counts[$fname]} > best_count )); then
            best_count=${_counts[$fname]}
            best_name="$fname"
            best_last="${_last[$fname]}"
        fi
    done

    if (( best_count >= CIRCUIT_THRESHOLD )) && [[ "$best_last" > "$cutoff_iso" ]]; then
        echo "OPEN $best_name $best_count $best_last"
    else
        echo "CLOSED"
    fi
}
