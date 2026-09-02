#!/usr/bin/env bash
# scripts/coord/lib/run-cache.sh — INFRA-2464
#
# The webhook receiver (scripts/ops/github-webhook-receiver.py) populates
# check_runs by head_sha/name (INFRA-1107), but never captured the workflow
# RUN's own databaseId — check_suite/workflow_run payloads carry an `id`
# field distinct from individual check-run rows. Callers that need a run id
# (e.g. to call `gh run rerun <id> --failed`) had no cache path and fell
# back to `gh run list --branch X --json databaseId`, which is a GraphQL
# call (top API burner per ZERO-WASTE-004/INFRA-1081) on every invocation.
#
# This helper provides a REST-backed, short-TTL file cache for "latest run
# id for branch X" so repeated lookups (e.g. flake-rerun retry loops) don't
# each pay a fresh network round-trip, and so the underlying fetch uses the
# REST actions/runs bucket instead of GraphQL `gh run list`.
#
# Source it:
#   source "$(dirname "$0")/lib/run-cache.sh"
#
# API:
#   run_cache_lookup_run_id <head_ref> [--max-age-s N]
#     stdout: databaseId of the most recent workflow run for that branch, or
#             empty on miss/error. rc=0 on hit (cache or REST), rc=1 on error.
#
# Env:
#   CHUMP_RUN_CACHE_DIR   — defaults to {repo_root}/.chump/run-cache
#   CHUMP_RUN_CACHE_TTL_S — staleness threshold (default 30s — run ids churn
#                           fast right after a push, unlike PR metadata)

[[ -n "${_CHUMP_RUN_CACHE_LIB:-}" ]] && return 0
_CHUMP_RUN_CACHE_LIB=1

_run_cache_dir() {
    if [[ -n "${CHUMP_RUN_CACHE_DIR:-}" ]]; then
        printf '%s' "$CHUMP_RUN_CACHE_DIR"
        return
    fi
    local root; root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    printf '%s/.chump/run-cache' "$root"
}

# run_cache_lookup_run_id <head_ref> [--max-age-s N]
#   Resolves the latest workflow run's databaseId for a branch. Reads a
#   per-branch cache file first; on miss/stale, fetches via REST
#   `gh api repos/X/actions/runs?branch=Y&per_page=1` (NOT `gh run list`,
#   which is GraphQL) and writes the result back.
run_cache_lookup_run_id() {
    local head_ref="${1:?run_cache_lookup_run_id <head_ref>}"
    shift || true
    local ttl="${CHUMP_RUN_CACHE_TTL_S:-30}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-age-s) ttl="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local dir; dir="$(_run_cache_dir)"
    mkdir -p "$dir" 2>/dev/null || true
    # Sanitize head_ref for use as a filename.
    local safe_ref="${head_ref//\//_}"
    local cache_file="$dir/${safe_ref}.run_id"
    local amb; amb="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [[ -f "$cache_file" ]]; then
        local mtime now age
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        now=$(date -u +%s)
        age=$((now - mtime))
        if [[ "$age" -lt "$ttl" ]]; then
            local cached; cached="$(cat "$cache_file" 2>/dev/null || true)"
            if [[ -n "$cached" ]]; then
                printf '{"ts":"%s","kind":"cache_hit","helper":"run_cache_lookup_run_id","target":"%s","age_s":%s}\n' \
                    "$ts" "$head_ref" "$age" >> "$amb" 2>/dev/null || true
                printf '%s' "$cached"
                return 0
            fi
        fi
    fi

    printf '{"ts":"%s","kind":"cache_miss","helper":"run_cache_lookup_run_id","target":"%s","reason":"stale_or_absent"}\n' \
        "$ts" "$head_ref" >> "$amb" 2>/dev/null || true

    # Resolve owner/repo via the memoized helper if available (avoids a
    # separate `gh repo view` burn); fall back to a direct call otherwise.
    local repo
    if command -v _cache_repo_nwo >/dev/null 2>&1; then
        repo="$(_cache_repo_nwo)"
    else
        repo="$(CHUMP_GH_CALL_CRITICALITY=background gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
    fi
    [[ -z "$repo" ]] && return 1

    local run_id
    if command -v chump_gh >/dev/null 2>&1; then
        run_id="$(CHUMP_GH_CALL_CRITICALITY=background chump_gh api \
            "repos/$repo/actions/runs?branch=${head_ref}&per_page=1" \
            --jq '.workflow_runs[0].id' 2>/dev/null || true)"
    else
        run_id="$(CHUMP_GH_CALL_CRITICALITY=background gh api \
            "repos/$repo/actions/runs?branch=${head_ref}&per_page=1" \
            --jq '.workflow_runs[0].id' 2>/dev/null || true)"
    fi
    [[ "$run_id" == "null" ]] && run_id=""
    [[ -z "$run_id" ]] && return 1

    printf '%s' "$run_id" > "$cache_file" 2>/dev/null || true
    printf '%s' "$run_id"
    return 0
}
