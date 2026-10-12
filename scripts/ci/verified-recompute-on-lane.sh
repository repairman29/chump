#!/usr/bin/env bash
# verified-recompute-on-lane.sh — RESILIENT-1562
#
# Event-driven companion to ci.yml's `verified` job. When audit.yml or
# integrations.yml (ACP smoke) completes, re-run `verified` for that head SHA
# so its verdict is recomputed from the lane's terminal state instead of
# depending on whether the 600s wall-clock poll window happened to overlap it.
#
# Usage: verified-recompute-on-lane.sh --sha SHA [--repo owner/repo] [--dry-run]
# Requires: gh CLI (GH_TOKEN with actions:write), jq.
# Exit 0 always for "nothing to do"; non-zero only on usage error.

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

# Latest CI run for this SHA.
run_id="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${SHA}&per_page=10" \
    -q '[.workflow_runs[]] | sort_by(.created_at) | last | .id // empty' 2>/dev/null || true)"
if [[ -z "$run_id" ]]; then
    echo "[verified-recompute] no ci.yml run for ${SHA}; nothing to recompute"
    exit 0
fi

job="$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs" --paginate \
    -q '[.jobs[] | select(.name == "verified")] | last // empty' 2>/dev/null || true)"
if [[ -z "$job" ]]; then
    echo "[verified-recompute] run ${run_id} has no verified job yet; it will poll the now-terminal lane itself"
    exit 0
fi

status="$(echo "$job" | jq -r '.status')"
conclusion="$(echo "$job" | jq -r '.conclusion // ""')"
job_id="$(echo "$job" | jq -r '.id')"

if [[ "$status" != "completed" ]]; then
    echo "[verified-recompute] verified still running (${status}); its own poll will see the terminal lane"
    exit 0
fi
if [[ "$conclusion" == "success" ]]; then
    echo "[verified-recompute] verified already success; nothing to do"
    exit 0
fi

echo "[verified-recompute] verified=${conclusion} for ${SHA}; re-running job ${job_id} (run ${run_id})"
if [[ "$DRY" -eq 1 ]]; then
    echo "[verified-recompute] dry-run: would 'gh run rerun ${run_id} --job ${job_id}'"
    exit 0
fi
gh run rerun "$run_id" --job "$job_id" || echo "[verified-recompute] WARN: rerun refused (run still active?); next lane completion retries"
