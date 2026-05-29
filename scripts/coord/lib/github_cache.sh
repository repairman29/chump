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

# ── INFRA-1999 Phase 1: feature-flagged Rust path ────────────────────────
# CHUMP_GITHUB_CACHE_RUST=1 routes all reader-side helpers through the
# chump-github-cache-cli binary (crates/chump-github-cache). The 493 LOC
# legacy bash body below is preserved untouched for the 1-week
# parallel-run validation window — Phase 1 ships the substrate, Phase 2
# (separate sub-gap under META-107) flips the default + decommissions
# the bash body.
#
# The shim re-implements the same shape the legacy helpers expose
# (printf to stdout, return-code semantics) on top of the Rust CLI's
# argv surface. The CLI's `lookup-pr` prints raw_payload_json; the
# others emit tab-separated rows that match the bash output. Callers
# downstream of these functions do not need to be aware of the flag.
if [[ "${CHUMP_GITHUB_CACHE_RUST:-0}" = "1" ]]; then
    _CHUMP_GH_CACHE_CLI="${CHUMP_GH_CACHE_CLI:-chump-github-cache-cli}"

    cache_lookup_pr() {
        local number="${1:?cache_lookup_pr <number>}"
        # The bash helper accepted `--max-age-s N` but the Rust path
        # ignores TTL in Phase 1 (the bash body's TTL+refetch is a
        # behaviour that comes back in Phase 2 alongside the REST
        # refresh loop). Consume and discard any flags.
        shift || true
        "$_CHUMP_GH_CACHE_CLI" lookup-pr "$number"
    }
    cache_lookup_checks() {
        local sha="${1:?cache_lookup_checks <head_sha>}"
        "$_CHUMP_GH_CACHE_CLI" lookup-checks "$sha"
    }
    cache_query_open_prs() {
        "$_CHUMP_GH_CACHE_CLI" query-open-prs
    }
    cache_query_open_prs_by_title() {
        local substr="${1:?cache_query_open_prs_by_title <substr>}"
        "$_CHUMP_GH_CACHE_CLI" query-open-prs-by-title "$substr"
    }
    cache_query_behind_prs() {
        "$_CHUMP_GH_CACHE_CLI" query-behind-prs
    }
    cache_refresh_open_prs() {
        # Phase 1 stub — Rust CLI prints `0` (nothing refilled).
        "$_CHUMP_GH_CACHE_CLI" refresh-open-prs
    }
    cache_lookup_pr_files() {
        local number="${1:?cache_lookup_pr_files <number>}"
        # Phase 1 stub: schema doesn't store files; CLI returns empty.
        # The legacy bash falls back to a background-tagged REST call;
        # callers under the Rust path get an empty line (which existing
        # callers handle as "no files known").
        "$_CHUMP_GH_CACHE_CLI" lookup-pr-files "$number" 2>/dev/null || echo ""
    }
    cache_lookup_pr_by_branch() {
        # Not yet ported in Phase 1 — fall through to the legacy bash
        # impl below by not returning here. The function definitions
        # below this if-block will overwrite any of the ones we just
        # defined, BUT the legacy body uses `[[ -n "${_CHUMP_GITHUB_CACHE_LIB:-}" ]] && return 0`
        # to no-op on re-source so we have to handle by NOT setting
        # CHUMP_GITHUB_CACHE_RUST when the caller needs by-branch.
        # Phase 1 acceptance: caller can flip the flag off per-call.
        echo "" ; return 2
    }
    return 0
fi
# ── End INFRA-1999 shim ───────────────────────────────────────────────────

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

# cache_query_dirty_armed_prs (INFRA-2186)
#   - Returns one PR number per line where mergeable_state='DIRTY' AND
#     auto_merge_enabled=1 AND merged_at IS NULL. Mirrors cache_query_behind_prs
#     for the DIRTY axis. Used by queue-driver.sh DIRTY auto-resolve loop.
#   - Empty cache or no rows -> empty output + cache_miss event; caller falls
#     back to `gh pr list`.
cache_query_dirty_armed_prs() {
    local db; db="$(_cache_db_path)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$db" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_dirty_armed_prs","target":"dirty_prs","reason":"db_not_found"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
        return 0
    fi
    local result
    result="$(sqlite3 "$db" "SELECT number FROM pr_state \
        WHERE mergeable_state = 'DIRTY' \
          AND auto_merge_enabled = 1 \
          AND merged_at IS NULL \
        ORDER BY number ASC" 2>/dev/null || true)"
    if [[ -z "$result" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_dirty_armed_prs","target":"dirty_prs","reason":"no_rows"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
    else
        local count; count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_query_dirty_armed_prs","target":"dirty_prs","age_s":0,"count":%s}\n' \
            "$ts" "$count" >> "$amb" 2>/dev/null || true
        printf '%s\n' "$result"
    fi
}

# cache_query_open_non_draft_prs (INFRA-2186)
#   - Returns one PR number per line for all open non-draft PRs (merged_at IS
#     NULL AND draft=0). Replaces `gh pr list --state open --json
#     number,isDraft` in queue-driver.sh cascade_rebase_if_hot. That call was
#     burning ~48 GraphQL points per hour during multi-PR cascade-rebase waves.
#   - Empty cache or no rows -> empty output + cache_miss event; caller falls
#     back to `gh pr list`.
cache_query_open_non_draft_prs() {
    local db; db="$(_cache_db_path)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$db" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_open_non_draft_prs","target":"open_prs","reason":"db_not_found"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
        return 0
    fi
    local result
    result="$(sqlite3 "$db" "SELECT number FROM pr_state \
        WHERE merged_at IS NULL \
          AND draft = 0 \
        ORDER BY number ASC" 2>/dev/null || true)"
    if [[ -z "$result" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_open_non_draft_prs","target":"open_prs","reason":"no_rows"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
    else
        local count; count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_query_open_non_draft_prs","target":"open_prs","age_s":0,"count":%s}\n' \
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
    _emit_offline_read_event cache_lookup_pr  # INFRA-1876
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
    # INFRA-1874: emit liaison_cache_stale when age exceeds the
    # Liaison-level stale threshold (default 600s per INFRA-1318 AC#3).
    # This is the operator-visible 'cache is degraded' signal — separate
    # from the per-call cache_miss/stale (which fires whenever age > ttl,
    # often 60s). Dashboards subscribe to this kind to surface a
    # 'fleet running degraded' message; cache_miss is too noisy for that.
    local liaison_threshold="${CHUMP_LIAISON_CACHE_STALE_S:-600}"
    if [[ "$age" -gt "$liaison_threshold" ]]; then
        printf '{"ts":"%s","kind":"liaison_cache_stale","helper":"cache_lookup_pr","target":"%s","age_s":%s,"threshold_s":%s,"last_webhook_at":null}\n' \
            "$ts" "$number" "$age" "$liaison_threshold" >> "$amb" 2>/dev/null || true
    fi
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
# INFRA-1368: add merge_state_status column idempotently.
try:
    conn.execute("ALTER TABLE pr_state ADD COLUMN merge_state_status TEXT")
    conn.commit()
except Exception:
    pass  # column already exists
conn.execute("""
INSERT INTO pr_state (
    number, head_ref, head_sha, base_ref, base_sha,
    mergeable_state, auto_merge_enabled, draft, merged_at,
    title, user_login, updated_at_api, fetched_at_local,
    raw_payload_json, merge_state_status
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(number) DO UPDATE SET
    head_ref=excluded.head_ref, head_sha=excluded.head_sha,
    base_ref=excluded.base_ref, base_sha=excluded.base_sha,
    mergeable_state=excluded.mergeable_state,
    merge_state_status=excluded.merge_state_status,
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
    pr.get("mergeable_state"),  # INFRA-1368: populate merge_state_status from REST
))
conn.commit()
PY
}

_cache_ambient_path() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    printf '%s/.chump-locks/ambient.jsonl' "$root"
}

# INFRA-1876: offline-mode tag emission for cache reads.
# When CHUMP_GITHUB_MODE=offline, the cache helpers emit
# kind=liaison_cache_offline_read so dashboards can show "operating offline"
# without scanning every cache_hit/cache_miss event. Debounced once per 60s
# per helper to avoid flooding ambient when callers loop.
# rc=0 always (never blocks the actual cache read).
_emit_offline_read_event() {
    local helper="${1:?helper}"
    [[ "${CHUMP_GITHUB_MODE:-}" == "offline" ]] || return 0
    local debounce="${CHUMP_LIAISON_OFFLINE_DEBOUNCE_S:-60}"
    local marker="${TMPDIR:-/tmp}/chump-liaison-offline-${helper}.marker"
    if [[ -f "$marker" ]]; then
        local mtime now age
        mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null)
        now=$(date -u +%s)
        if [[ -n "$mtime" ]]; then
            age=$((now - mtime))
            [[ "$age" -lt "$debounce" ]] && return 0
        fi
    fi
    : > "$marker" 2>/dev/null
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"liaison_cache_offline_read","helper":"%s","debounce_s":%s}\n' \
        "$ts" "$helper" "$debounce" >> "$amb" 2>/dev/null || true
}

# INFRA-1275: cache_query_open_prs
#   stdout: tab-separated lines `<number>\t<title>\t<head_ref>` per open PR
#           (merged_at IS NULL). Empty on miss/empty.
#   Used by ambient-glance.sh + gap-preflight.sh to replace `gh pr list`.
#   The caller can grep by title substring (cheap) instead of paying
#   GitHub's GraphQL secondary-rate-limit tax.
cache_query_open_prs() {
    _emit_offline_read_event cache_query_open_prs  # INFRA-1876
    local db; db="$(_cache_db_path)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$db" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_open_prs","target":"open_prs","reason":"db_not_found"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
        return 0
    fi
    local result
    result="$(sqlite3 -separator $'\t' "$db" \
        "SELECT number, COALESCE(title,''), COALESCE(head_ref,'') \
         FROM pr_state WHERE merged_at IS NULL \
         ORDER BY number DESC" 2>/dev/null || true)"
    if [[ -z "$result" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_open_prs","target":"open_prs","reason":"no_rows"}\n' \
            "$ts" >> "$amb" 2>/dev/null || true
    else
        local count; count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_query_open_prs","target":"open_prs","age_s":0,"count":%s}\n' \
            "$ts" "$count" >> "$amb" 2>/dev/null || true
        printf '%s\n' "$result"
    fi
}

# INFRA-1275: cache_query_open_prs_by_title <substr>
#   stdout: tab-separated lines `<number>\t<title>\t<head_ref>` for open PRs
#           whose title contains <substr> (case-insensitive). Empty on miss.
#   Convenience wrapper over cache_query_open_prs — avoids leaking the
#   sqlite LIKE pattern into the caller.
cache_query_open_prs_by_title() {
    local substr="${1:?cache_query_open_prs_by_title <substr>}"
    local db; db="$(_cache_db_path)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -f "$db" ]] || { printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_open_prs_by_title","target":"%s","reason":"db_not_found"}\n' "$ts" "$substr" >> "$amb" 2>/dev/null || true; return 0; }
    # Escape SQL single-quotes in the substring.
    local esc="${substr//\'/\'\'}"
    local result
    result="$(sqlite3 -separator $'\t' "$db" \
        "SELECT number, COALESCE(title,''), COALESCE(head_ref,'') \
         FROM pr_state \
         WHERE merged_at IS NULL \
           AND LOWER(title) LIKE LOWER('%${esc}%') \
         ORDER BY number DESC" 2>/dev/null || true)"
    if [[ -z "$result" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_query_open_prs_by_title","target":"%s","reason":"no_match"}\n' \
            "$ts" "$substr" >> "$amb" 2>/dev/null || true
    else
        local count; count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_query_open_prs_by_title","target":"%s","age_s":0,"count":%s}\n' \
            "$ts" "$substr" "$count" >> "$amb" 2>/dev/null || true
        printf '%s\n' "$result"
    fi
}

# INFRA-1275: cache_refresh_open_prs
#   Bulk-fetch all open PRs from REST (NOT GraphQL — avoids the secondary
#   rate-limit ceiling) and write them into pr_state. Use this from a caller
#   that just got an empty cache_query_open_prs result, then re-query the
#   cache. One REST round-trip per refill, capped at 100 PRs (page size).
#
#   rc=0 on success, rc=1 if `gh repo view` or `gh api` failed.
#   Stdout: number of rows written (integer).
cache_refresh_open_prs() {
    local db; db="$(_cache_db_path)"
    mkdir -p "$(dirname "$db")" 2>/dev/null || true
    local repo
    repo="$(CHUMP_GH_CALL_CRITICALITY=background gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
    [[ -z "$repo" ]] && return 1
    local resp
    resp="$(CHUMP_GH_CALL_CRITICALITY=background gh api \
        "repos/$repo/pulls?state=open&per_page=100" 2>/dev/null)"
    [[ -z "$resp" ]] && return 1
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local written
    written="$(python3 - "$db" "$resp" <<'PY'
import json, sqlite3, sys
from datetime import datetime, timezone

db_path, payload_raw = sys.argv[1], sys.argv[2]
try:
    prs = json.loads(payload_raw)
except Exception:
    print(0); sys.exit(0)
if not isinstance(prs, list):
    print(0); sys.exit(0)
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
written = 0
for pr in prs:
    n = pr.get("number")
    if not isinstance(n, int):
        continue
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
        n,
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
        json.dumps(pr),
    ))
    written += 1
conn.commit()
print(written)
PY
)"
    printf '{"ts":"%s","kind":"cache_refilled","helper":"cache_refresh_open_prs","rows":%s,"source":"rest"}\n' \
        "$ts" "${written:-0}" >> "$amb" 2>/dev/null || true
    printf '%s' "${written:-0}"
}

# INFRA-1275: cache_lookup_pr_files <number>
#   stdout: comma-separated file paths for PR <number>.
#   The cache schema doesn't store file paths (no webhook event populates them),
#   so this is a thin background-tagged REST wrapper. Future work: extend
#   pr_state with a files_csv column + webhook receiver populates it.
#   Single REST call per PR; background-tagged so it yields the bucket to
#   ship-blocking calls per INFRA-1080.
cache_lookup_pr_files() {
    local number="${1:?cache_lookup_pr_files <number>}"
    local repo
    repo="$(CHUMP_GH_CALL_CRITICALITY=background gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
    [[ -z "$repo" ]] && return 1
    CHUMP_GH_CALL_CRITICALITY=background gh api "repos/$repo/pulls/$number/files" \
        --jq '[.[].filename] | join(",")' 2>/dev/null || echo ""
}

# INFRA-1082: cache_lookup_pr_by_branch <head_ref>
#   Resolve branch name → PR number + raw JSON from cache.
#   stdout: raw_payload_json (same shape as cache_lookup_pr)
#   rc=0 on hit (cache or REST fallback), rc=2 on miss.
#   Falls back to REST gh api if the cache has no row for this branch.
#   Used by bot-merge.sh to replace `gh pr view "$BRANCH"` lookups.
cache_lookup_pr_by_branch() {
    local head_ref="${1:?cache_lookup_pr_by_branch <head_ref>}"
    local db; db="$(_cache_db_path)"
    local amb; amb="$(_cache_ambient_path)"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$db" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_lookup_pr_by_branch","target":"%s","reason":"db_not_found"}\n' \
            "$ts" "$head_ref" >> "$amb" 2>/dev/null || true
        return 2
    fi
    # Escape single-quotes in branch name for SQL
    local esc_ref="${head_ref//\'/\'\'}"
    local row age
    row="$(sqlite3 "$db" \
        "SELECT number, raw_payload_json, \
                CAST((strftime('%s','now') - strftime('%s', fetched_at_local)) AS INTEGER) AS age \
         FROM pr_state WHERE head_ref = '${esc_ref}' AND merged_at IS NULL \
         ORDER BY number DESC LIMIT 1" 2>/dev/null || true)"
    if [[ -z "$row" ]]; then
        printf '{"ts":"%s","kind":"cache_miss","helper":"cache_lookup_pr_by_branch","target":"%s","reason":"not_found"}\n' \
            "$ts" "$head_ref" >> "$amb" 2>/dev/null || true
        return 2
    fi
    # sqlite returns "number|json|age" with default | separator
    age="${row##*|}"
    local rest="${row%|*}"
    local payload="${rest#*|}"
    local number="${rest%%|*}"
    local ttl="${CHUMP_CACHE_TTL_S:-60}"
    if [[ "$age" =~ ^[0-9]+$ ]] && [[ "$age" -lt "$ttl" ]]; then
        printf '{"ts":"%s","kind":"cache_hit","helper":"cache_lookup_pr_by_branch","target":"%s","pr":%s,"age_s":%s}\n' \
            "$ts" "$head_ref" "$number" "$age" >> "$amb" 2>/dev/null || true
        printf '%s' "$payload"
        return 0
    fi
    # Stale: re-fetch by number (we know it now)
    printf '{"ts":"%s","kind":"cache_miss","helper":"cache_lookup_pr_by_branch","target":"%s","pr":%s,"reason":"stale","age_s":%s}\n' \
        "$ts" "$head_ref" "$number" "$age" >> "$amb" 2>/dev/null || true
    _cache_fetch_and_store "$number"
    return 0
}

# INFRA-1107: cache_lookup_checks <head_sha>
#   stdout: tab-separated lines `<name>\t<status>\t<conclusion>` per cached
#           check_run for the given head SHA. Empty on miss.
#   Used by bot-merge to read CI status from sqlite instead of polling
#   `gh api repos/X/commits/SHA/check-runs`.
cache_lookup_checks() {
    local sha="${1:?cache_lookup_checks <head_sha>}"
    _emit_offline_read_event cache_lookup_checks  # INFRA-1876
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
