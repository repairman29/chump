#!/usr/bin/env bash
# scripts/coord/lib/github_cache.sh — INFRA-1081
#
# Reader-side helper for the github webhook cache (.chump/github_cache.db).
# Webhook receiver (scripts/ops/github-webhook-receiver.py) writes events.
# Periodic reconcile (scripts/ops/github-cache-reconcile.sh) fills gaps.
# This lib reads + falls back to REST on miss/stale.
#
# Source it:
#   source "$(dirname "$0")/lib/github_cache.sh"
#
# API:
#   cache_lookup_pr <number> [--max-age-s N]
#     stdout: JSON row (sqlite output) or empty on miss/error
#     rc=0 if fresh, rc=1 if served from sqlite but stale, rc=2 if miss
#
#   cache_query_behind_prs
#     stdout: numbers of open PRs with mergeable_state='BEHIND' AND auto_merge_enabled=1,
#     one per line, sorted ascending. Used by queue-driver.
#
# Env:
#   CHUMP_CACHE_DB     — defaults to {repo_root}/.chump/github_cache.db
#   CHUMP_CACHE_TTL_S  — staleness threshold (default 60)
#
# Cache empty / DB missing: falls through cleanly. Callers should be
# resilient (e.g. queue-driver falls back to one `gh pr list` direct call
# on empty cache to populate the first time).

[[ -n "${_CHUMP_GITHUB_CACHE_LIB:-}" ]] && return 0
_CHUMP_GITHUB_CACHE_LIB=1

_cache_db_path() {
    if [[ -n "${CHUMP_CACHE_DB:-}" ]]; then
        printf '%s' "$CHUMP_CACHE_DB"
        return
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    printf '%s/.chump/github_cache.db' "$root"
}

# cache_query_behind_prs — returns PR numbers for open BEHIND + auto-merge-armed
# rows. Empty stdout if the cache is empty or the DB doesn't exist yet.
cache_query_behind_prs() {
    local db; db="$(_cache_db_path)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$db" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_behind_prs","target":"behind_prs","reason":"db_not_found"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
        return 0
    fi
    local result
    result="$(sqlite3 "$db" "SELECT number FROM pr_state \
        WHERE mergeable_state = 'BEHIND' \
          AND auto_merge_enabled = 1 \
          AND merged_at IS NULL \
        ORDER BY number ASC" 2>/dev/null || true)"
    if [[ -z "$result" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_behind_prs","target":"behind_prs","reason":"no_rows"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
    else
        local count; count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_query_behind_prs","target":"behind_prs","age_s":0,"count":%s}\n' \
            "$ts" "$count" >> "$amb" 2>/dev/null || true
        printf '%s\n' "$result"
    fi
}

# cache_lookup_pr <number> [--max-age-s N]
#   - Returns the cache row's raw_payload_json on stdout (if present).
#   - On miss: rc=2, empty stdout.
#   - On stale-by-TTL (default 60s): emits kind=cache_miss to ambient, then
#     fetches via REST `gh api repos/X/pulls/N`, writes back, returns rc=0
#     with the new row.
cache_lookup_pr() {
    local number="${1:?cache_lookup_pr <number>}"
    shift || true
    local ttl="${CHUMP_CACHE_TTL_S:-60}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-age-s) ttl="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local db; db="$(_cache_db_path)"
    [[ -f "$db" ]] || return 2

    # Read row + age in one query
    local row age
    row="$(sqlite3 "$db" \
        "SELECT raw_payload_json, \
                CAST((strftime('%s','now') - strftime('%s', fetched_at_local)) AS INTEGER) AS age \
         FROM pr_state WHERE number = $number" 2>/dev/null || true)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -z "$row" ]]; then
        # Pure cache miss — emit event + fetch via REST.
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_lookup_pr","target":"%s","reason":"not_found"}\n' \
            "$ts" "$number" >> "$amb" 2>/dev/null || true
        _cache_fetch_and_store "$number"
        return 0
    fi

    # sqlite returns "<json>|<age>" (default | separator).
    age="${row##*|}"
    local payload="${row%|*}"
    if [[ "$age" =~ ^[0-9]+$ ]] && [[ "$age" -lt "$ttl" ]]; then
        # Fresh — emit cache_hit event + return on stdout, rc=0.
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_lookup_pr","target":"%s","age_s":%s}\n' \
            "$ts" "$number" "$age" >> "$amb" 2>/dev/null || true
        printf '%s' "$payload"
        return 0
    fi

    # Stale — emit cache_miss event + re-fetch.
    printf '{"ts":"%s","kind":"cache_miss","helper":"cache_lookup_pr","target":"%s","reason":"stale","age_s":%s,"ttl_s":%s}\n' \
        "$ts" "$number" "$age" "$ttl" >> "$amb" 2>/dev/null || true
    _cache_fetch_and_store "$number"
}

_cache_fetch_and_store() {
    local number="${1:?}"
    local db; db="$(_cache_db_path)"
    mkdir -p "$(dirname "$db")" 2>/dev/null || true
    local repo
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
    [[ -z "$repo" ]] && return 1
    local resp
    resp="$(gh api "repos/$repo/pulls/$number" 2>/dev/null)"
    [[ -z "$resp" ]] && return 1
    # Print to stdout for the caller, then write to cache.
    printf '%s' "$resp"
    python3 - "$db" "$number" "$resp" <<'PY'
import json, sqlite3, sys
from datetime import datetime, timezone

db_path, number, payload_raw = sys.argv[1], int(sys.argv[2]), sys.argv[3]
pr = json.loads(payload_raw)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

conn = sqlite3.connect(db_path)
conn.executescript("""
CREATE TABLE IF NOT EXISTS pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
CREATE INDEX IF NOT EXISTS pr_state_behind_armed ON pr_state(mergeable_state, auto_merge_enabled);
""")
conn.execute("""
INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(number) DO UPDATE SET
    head_ref=excluded.head_ref, head_sha=excluded.head_sha,
    base_ref=excluded.base_ref, base_sha=excluded.base_sha,
    mergeable_state=excluded.mergeable_state,
    auto_merge_enabled=excluded.auto_merge_enabled,
    draft=excluded.draft, merged_at=excluded.merged_at,
    title=excluded.title, user_login=excluded.user_login,
    updated_at_api=excluded.updated_at_api,
    fetched_at_local=excluded.fetched_at_local,
    raw_payload_json=excluded.raw_payload_json
""", (
    number,
    (pr.get("head") or {}).get("ref"),
    (pr.get("head") or {}).get("sha"),
    (pr.get("base") or {}).get("ref"),
    (pr.get("base") or {}).get("sha"),
    pr.get("mergeable_state"),
    1 if pr.get("auto_merge") else 0,
    1 if pr.get("draft") else 0,
    pr.get("merged_at"),
    pr.get("title"),
    (pr.get("user") or {}).get("login"),
    pr.get("updated_at") or now,
    now,
    payload_raw,
))
conn.commit()
PY
}

_cache_ambient_path() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    printf '%s/.chump-locks/ambient.jsonl' "$root"
}

# INFRA-1107: cache_lookup_checks <head_sha>
#   stdout: tab-separated lines `<name>\t<status>\t<conclusion>` per cached
#           check_run for the given head SHA. Empty on miss.
#   Used by bot-merge to read CI status from sqlite instead of polling
#   `gh api repos/X/commits/SHA/check-runs`.
cache_lookup_checks() {
    local sha="${1:?cache_lookup_checks <head_sha>}"
    local db; db="$(_cache_db_path)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$db" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_lookup_checks","target":"%s","reason":"db_not_found"}\n' \
            "$ts" "$sha" >> "$amb" 2>/dev/null || true
        return 0
    fi
    local result
    result="$(sqlite3 -separator $'\t' "$db" \
        "SELECT name, COALESCE(status,''), COALESCE(conclusion,'') \
         FROM check_runs WHERE head_sha = '$sha' ORDER BY name" 2>/dev/null || true)"
    if [[ -z "$result" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_lookup_checks","target":"%s","reason":"no_rows"}\n' \
            "$ts" "$sha" >> "$amb" 2>/dev/null || true
    else
        local count; count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_lookup_checks","target":"%s","age_s":0,"count":%s}\n' \
            "$ts" "$sha" "$count" >> "$amb" 2>/dev/null || true
        printf '%s\n' "$result"
    fi
}
