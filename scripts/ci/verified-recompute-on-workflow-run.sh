#!/usr/bin/env bash
# verified-recompute-on-workflow-run.sh — RESILIENT-1562
#
# `verified` (ci.yml) polls audit/ACP with a wall-clock window that can open
# too late. This is the event-driven half: when audit.yml / integrations.yml
# completes for a SHA, re-run ONLY the `verified` job of that SHA's CI run if
# it is not already green, so its verdict is a function of audit/ACP terminal
# state rather than of timing.
#
# Usage: verified-recompute-on-workflow-run.sh --sha SHA [--repo owner/repo] [--dry-run]
# Requires: gh (GH_TOKEN with actions: write), jq.
set -euo pipefail

REPO="${GH_REPO:-repairman29/chump}"
SHA=""
DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)     SHA="$2"; shift 2 ;;
        --repo)    REPO="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "[verified-recompute] unknown arg: $1" >&2; exit 3 ;;
    esac
done
[[ -n "$SHA" ]] || { echo "[verified-recompute] --sha required" >&2; exit 3; }

runs="$(gh api "repos/${REPO}/actions/runs?head_sha=${SHA}&per_page=50" -q '[.workflow_runs[] | select(.name == "CI")] | sort_by(.created_at) | reverse')"
n="$(echo "$runs" | jq 'length')"
if [[ "$n" -eq 0 ]]; then
    echo "[verified-recompute] no CI run for ${SHA}; nothing to do"
    exit 0
fi

echo "$runs" | jq -r '.[] | "\(.id) \(.status)"' | while read -r run_id run_status; do
    # A still-running CI run's verified job will see audit's terminal state itself.
    if [[ "$run_status" != "completed" ]]; then
        echo "[verified-recompute] CI run ${run_id} still ${run_status}; skip"
        continue
    fi
    job="$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100" --paginate -q '.jobs[] | select(.name == "verified") | "\(.id) \(.conclusion)"' | tail -1)"
    [[ -n "$job" ]] || { echo "[verified-recompute] run ${run_id}: no verified job"; continue; }
    job_id="${job% *}"; concl="${job#* }"
    if [[ "$concl" == "success" || "$concl" == "skipped" ]]; then
        echo "[verified-recompute] run ${run_id}: verified already ${concl}; skip"
        continue
    fi
    echo "[verified-recompute] run ${run_id}: verified=${concl}; re-running job ${job_id}"
    if [[ "$DRY" -eq 1 ]]; then continue; fi
    gh api -X POST "repos/${REPO}/actions/jobs/${job_id}/rerun" >/dev/null \
        || echo "[verified-recompute] WARN: rerun of job ${job_id} failed (non-fatal)" >&2
done
