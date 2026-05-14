#!/usr/bin/env bash
# RESILIENT-006: PR-stale auto-rebase.
#
# When a PR that has auto-merge armed is BLOCKED because of CI failures on
# checks that have since PASSED on main HEAD, rebases the branch onto main,
# force-pushes with lease, and re-arms auto-merge.
#
# This unwedges PRs like #1433 (17h stall: checks failed transiently on an
# older main, later passed on main, but the PR branch never got rebased).
#
# Usage:
#   bash scripts/coord/pr-rescue.sh [--pr <N>] [--repo <owner/repo>]
#
# Env vars:
#   GH_TOKEN              — GitHub token (exits 0 silently if absent)
#   GITHUB_REPOSITORY     — <owner/repo> (fallback: git remote get-url origin)
#   PR_RESCUE_STALE_HOURS — Only touch PRs blocked >= this many hours (default: 4)
#
# Exits:
#   0 — completed (may have rescued 0 PRs)
#   1 — error (bad args, git failure, etc.)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
STALE_HOURS="${PR_RESCUE_STALE_HOURS:-4}"
# INFRA-1016: REST-only mode — skip auto-merge arm (unavailable via REST) and
# do an immediate merge instead. Use when GraphQL bucket is exhausted.
REST_ONLY="${CHUMP_PR_RESCUE_REST_ONLY:-0}"
# INFRA-1153: wall-clock timeout so pr-rescue never runs >5 min and hammers
# the secondary GitHub rate limit. Processes that survived 335+ min were the
# root cause of the 2026-05-13 secondary rate limit outage.
TIMEOUT_S="${CHUMP_PR_RESCUE_TIMEOUT_S:-300}"
_PR_RESCUE_START="$(date -u +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# INFRA-999: API cost telemetry. CHUMP_GH_SCRIPT tags the script in
# the emitted ambient.jsonl `github_api_call` lines.
# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# INFRA-1109: cache-first per-PR meta lookup via INFRA-1081 cache.
# shellcheck source=lib/github_cache.sh
[[ -f "${SCRIPT_DIR}/lib/github_cache.sh" ]] && source "${SCRIPT_DIR}/lib/github_cache.sh"
export CHUMP_GH_SCRIPT="pr-rescue.sh"
REPO="${GITHUB_REPOSITORY:-}"
TARGET_PR=""

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr) TARGET_PR="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --rest-only) REST_ONLY=1; shift ;;
        *) echo "[pr-rescue] ERROR: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[pr-rescue] $*" >&2; }

emit_ambient() {
    local kind="$1" pr_num="$2" detail="${3:-}"
    local locks_dir="${REPO_ROOT}/.chump-locks"
    mkdir -p "${locks_dir}" 2>/dev/null || true
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s","pr":%s,"detail":"%s"}\n' \
        "${ts}" "${kind}" "${pr_num}" "${detail}" \
        >> "${locks_dir}/ambient.jsonl" 2>/dev/null || true
}

# ── Guard: skip if no GH_TOKEN ───────────────────────────────────────────────
if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    log "No GH_TOKEN set — skipping PR rescue (non-CI environment)."
    exit 0
fi

# Resolve repo from git remote if not set
if [[ -z "${REPO}" ]]; then
    REPO="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||;s|.git$||' || true)"
fi
if [[ -z "${REPO}" ]]; then
    log "ERROR: Could not determine GITHUB_REPOSITORY."
    exit 1
fi

log "PR rescue scan for ${REPO} (stale threshold: ${STALE_HOURS}h${REST_ONLY:+, REST-only mode})."

# ── Collect candidate PRs ─────────────────────────────────────────────────────
# We want PRs that:
#   1. Are OPEN
#   2. Have auto-merge armed (autoMergeRequest != null)
#   3. Are mergeable (not conflicting — conflicts need human help)
#   4. Have been open for at least STALE_HOURS hours
if [[ -n "${TARGET_PR}" ]]; then
    PR_NUMBERS="${TARGET_PR}"
else
    PR_NUMBERS="$(chump_gh api \
        "repos/${REPO}/pulls?state=open&per_page=50" \
        --jq '[.[] | select(.auto_merge != null) | .number] | .[]' \
        2>/dev/null || echo '')"
fi

if [[ -z "${PR_NUMBERS}" ]]; then
    log "No auto-merge-armed PRs found."
    exit 0
fi

# Get main HEAD SHA once for check comparison
MAIN_SHA="$(chump_gh api "repos/${REPO}/git/ref/heads/main" --jq .object.sha 2>/dev/null || echo '')"
if [[ -z "${MAIN_SHA}" ]]; then
    log "ERROR: Could not resolve main HEAD SHA."
    exit 1
fi
log "main HEAD: ${MAIN_SHA}"

RESCUED=0
SKIPPED=0
FAILED=0

for PR_NUM in ${PR_NUMBERS}; do
    # ── INFRA-1153: wall-clock timeout guard ──────────────────────────────────
    _elapsed=$(( $(date -u +%s) - _PR_RESCUE_START ))
    if [[ $_elapsed -ge $TIMEOUT_S ]]; then
        log "WARN: wall-clock timeout (${TIMEOUT_S}s) reached after ${_elapsed}s — stopping early (INFRA-1153)."
        emit_ambient "pr_rescue_timeout" "0" "elapsed=${_elapsed}s remaining_prs_skipped=true"
        break
    fi

    # ── Fetch PR metadata (INFRA-1109 cache-first) ────────────────────────────
    # Prefer reading from .chump/github_cache.db (INFRA-1081, populated by
    # webhooks). cache_lookup_pr emits kind=cache_miss + falls back to REST
    # when stale/missing — zero API calls when cache is warm, one when cold.
    PR_META=""
    if declare -F cache_lookup_pr >/dev/null 2>&1; then
        PR_META="$(cache_lookup_pr "${PR_NUM}" 2>/dev/null)"
    fi
    if [[ -z "$PR_META" ]]; then
        # Cache lib not loaded or cache empty + REST fallback failed.
        PR_META="$(chump_gh api "repos/${REPO}/pulls/${PR_NUM}" 2>/dev/null)" || {
            log "WARN: Could not fetch PR #${PR_NUM} — skipping."
            continue
        }
    fi

    PR_STATE="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state'])")"
    MERGEABLE="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mergeable','') or '')")"
    PR_BRANCH="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['head']['ref'])")"
    PR_CREATED="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['created_at'])")"

    if [[ "${PR_STATE}" != "open" ]]; then
        log "PR #${PR_NUM}: not open — skip."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ "${MERGEABLE}" == "CONFLICTING" ]]; then
        log "PR #${PR_NUM}: has merge conflicts — skip (human intervention needed)."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # ── Staleness check ───────────────────────────────────────────────────────
    CREATED_EPOCH="$(date -d "${PR_CREATED}" +%s 2>/dev/null \
        || python3 -c "import datetime,sys; \
           s='${PR_CREATED}'; \
           dt=datetime.datetime.strptime(s,'%Y-%m-%dT%H:%M:%SZ'); \
           print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))")"
    NOW_EPOCH="$(date -u +%s)"
    AGE_HOURS=$(( (NOW_EPOCH - CREATED_EPOCH) / 3600 ))

    if [[ ${AGE_HOURS} -lt ${STALE_HOURS} ]]; then
        log "PR #${PR_NUM}: age ${AGE_HOURS}h < threshold ${STALE_HOURS}h — skip."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # ── Check if PR CI has failures that passed on main ───────────────────────
    # Get latest commit check runs for the PR HEAD
    PR_HEAD_SHA="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['head']['sha'])")"

    FAILING_CHECKS="$(chump_gh api \
        "repos/${REPO}/commits/${PR_HEAD_SHA}/check-runs?per_page=50" \
        --jq '[.check_runs[] | select(.conclusion == "failure") | .name] | .[]' \
        2>/dev/null || echo '')"

    if [[ -z "${FAILING_CHECKS}" ]]; then
        log "PR #${PR_NUM}: no failing checks — skip (may already be passing or pending)."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check if those same check names passed on main HEAD
    MAIN_PASSING_CHECKS="$(chump_gh api \
        "repos/${REPO}/commits/${MAIN_SHA}/check-runs?per_page=50" \
        --jq '[.check_runs[] | select(.conclusion == "success") | .name] | .[]' \
        2>/dev/null || echo '')"

    # Find overlap: failing on PR but passing on main
    RESCUABLE=0
    for CHECK in ${FAILING_CHECKS}; do
        if echo "${MAIN_PASSING_CHECKS}" | grep -qxF "${CHECK}"; then
            log "PR #${PR_NUM}: check '${CHECK}' fails on PR but passes on main HEAD."
            RESCUABLE=1
            break
        fi
    done

    if [[ ${RESCUABLE} -eq 0 ]]; then
        log "PR #${PR_NUM}: failing checks are not transient (not passing on main) — skip."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    log "PR #${PR_NUM} (branch: ${PR_BRANCH}): rescue candidate — rebasing onto main."
    emit_ambient "pr_rescue_triggered" "${PR_NUM}" "branch=${PR_BRANCH} age=${AGE_HOURS}h"

    # ── Rebase via temp clone ─────────────────────────────────────────────────
    TEMP_DIR="$(mktemp -d)"
    RESCUE_OK=0

    (
        set -euo pipefail
        git clone --quiet \
            "$(git -C "${REPO_ROOT}" remote get-url origin)" \
            "${TEMP_DIR}/repo" \
            --depth 50 --branch "${PR_BRANCH}" 2>&1 | tail -2

        git -C "${TEMP_DIR}/repo" config user.name  "chump-pr-rescue"
        git -C "${TEMP_DIR}/repo" config user.email "chump-pr-rescue@users.noreply.github.com"

        # Fetch main and rebase
        git -C "${TEMP_DIR}/repo" fetch --quiet origin main 2>&1 | tail -2
        CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 \
            git -C "${TEMP_DIR}/repo" rebase origin/main

        # Force-push with lease
        git -C "${TEMP_DIR}/repo" push origin "${PR_BRANCH}" \
            --force-with-lease --quiet 2>&1 | tail -2
    ) && RESCUE_OK=1 || RESCUE_OK=0

    rm -rf "${TEMP_DIR}"

    if [[ ${RESCUE_OK} -eq 1 ]]; then
        if [[ "${REST_ONLY}" == "1" ]]; then
            # INFRA-1016: REST path — immediate merge (no auto-merge available via REST).
            # Accepted limitation: only use this when GraphQL is exhausted and PR is
            # already green (status checks passing). Not suitable for arming auto-merge.
            chump_gh api -X PUT "repos/${REPO}/pulls/${PR_NUM}/merge" \
                -f merge_method=squash 2>/dev/null || true
            log "PR #${PR_NUM}: rebased + merged (REST-only, no auto-merge). RESCUED."
        else
            # INFRA-1113: delegate to centralized armer (5s spacing, retry on rate-limit).
            bash "${SCRIPT_DIR}/auto-merge-armer.sh" --pr "${PR_NUM}" --repo "${REPO}" \
                2>/dev/null || true
            log "PR #${PR_NUM}: rebased + re-armed. RESCUED."
        fi
        emit_ambient "pr_rescue_completed" "${PR_NUM}" "branch=${PR_BRANCH} rest_only=${REST_ONLY}"
        RESCUED=$((RESCUED + 1))
    else
        log "PR #${PR_NUM}: rebase failed (conflicts?). FAILED."
        emit_ambient "pr_rescue_failed" "${PR_NUM}" "branch=${PR_BRANCH} reason=rebase_conflict"
        FAILED=$((FAILED + 1))
    fi
done

log "Done. rescued=${RESCUED} skipped=${SKIPPED} failed=${FAILED}"
