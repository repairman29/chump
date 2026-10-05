#!/usr/bin/env bash
# ci-guards.sh — RESILIENT-018
#
# Sourceable library: guard any CI test/script that calls `gh api` / `gh pr`
# on GH_TOKEN (or GITHUB_TOKEN) actually being present. GitHub Actions does
# not auto-export GH_TOKEN into every job (it must be wired per-step/per-job),
# so a script that assumes it's always there fails persistently in any
# workflow that didn't wire it — see e2e-pwa / INFRA-1846 precedent.
#
# Usage (in any CI script that calls gh api/gh pr):
#   source "$(dirname "$0")/lib/ci-guards.sh"
#   check_gh_token_or_skip "<workflow_name>" "<job_name>"
#   # ... only reached if GH_TOKEN/GITHUB_TOKEN is set ...
#   gh api rate_limit
#
# check_gh_token_or_skip exits the calling script with status 0 (pass, not
# fail) and emits an ambient kind=ci_gh_token_missing_skip event when neither
# GH_TOKEN nor GITHUB_TOKEN is set. If a token is present it returns 0 and
# the caller continues.
#
# Environment:
#   CHUMP_AMBIENT_LOG   path to ambient.jsonl (default: .chump-locks/ambient.jsonl)

_CI_GUARDS_LOADED=1

_ci_guards_ambient_path() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    echo "${CHUMP_AMBIENT_LOG:-${repo_root}/.chump-locks/ambient.jsonl}"
}

# check_gh_token_or_skip [<workflow_name>] [<job_name>]
#   Defaults workflow_name/job_name to $GITHUB_WORKFLOW / $GITHUB_JOB when
#   the caller doesn't pass them explicitly (both set by GitHub Actions).
check_gh_token_or_skip() {
    if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
        return 0
    fi

    local workflow_name="${1:-${GITHUB_WORKFLOW:-unknown}}"
    local job_name="${2:-${GITHUB_JOB:-unknown}}"
    local ts ambient
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ambient="$(_ci_guards_ambient_path)"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"ci_gh_token_missing_skip","workflow_name":"%s","job_name":"%s"}\n' \
        "$ts" "$workflow_name" "$job_name" \
        >> "$ambient" 2>/dev/null || true

    echo "WARN: GH_TOKEN/GITHUB_TOKEN not set — skipping gh-dependent checks (workflow=${workflow_name} job=${job_name})" >&2
    exit 0
}
