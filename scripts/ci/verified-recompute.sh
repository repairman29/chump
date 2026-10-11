#!/usr/bin/env bash
# verified-recompute.sh — RESILIENT-1562
# Re-run the ci.yml `verified` job for a SHA once a cross-workflow lane (audit /
# ACP smoke) has reached a terminal state, so the verdict derives from the
# lane's terminal state, not a fixed poll window. No-op if `verified` already
# succeeded or is still running (its own poll will see the terminal lane).
#
# Usage: verified-recompute.sh --sha SHA [--repo owner/repo] [--wait-s N]
set -euo pipefail

REPO="${GH_REPO:-repairman29/chump}"
SHA=""
WAIT_S=300
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)    SHA="$2"; shift 2 ;;
        --repo)   REPO="$2"; shift 2 ;;
        --wait-s) WAIT_S="$2"; shift 2 ;;
        *) echo "[verified-recompute] unknown arg: $1" >&2; exit 3 ;;
    esac
done
[[ -n "$SHA" ]] || { echo "[verified-recompute] --sha required" >&2; exit 3; }

deadline=$(( $(date +%s) + WAIT_S ))
while true; do
    run_json="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${SHA}&per_page=1" \
        -q '.workflow_runs[0] // empty' 2>/dev/null || true)"
    if [[ -z "$run_json" ]]; then
        echo "[verified-recompute] no ci.yml run for ${SHA}; nothing to do"
        exit 0
    fi
    run_id="$(echo "$run_json" | jq -r '.id')"
    status="$(echo "$run_json" | jq -r '.status')"
    [[ "$status" == "completed" ]] && break
    if [[ $(date +%s) -ge $deadline ]]; then
        echo "[verified-recompute] run ${run_id} still ${status}; its own poll will observe the terminal lane"
        exit 0
    fi
    sleep 15
done

job="$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs" --paginate \
    -q '[.jobs[] | select(.name == "verified")] | last // empty' 2>/dev/null || true)"
if [[ -z "$job" ]]; then
    echo "[verified-recompute] no verified job in run ${run_id}"
    exit 0
fi
conclusion="$(echo "$job" | jq -r '.conclusion // ""')"
if [[ "$conclusion" == "success" ]]; then
    echo "[verified-recompute] verified already success; no re-run"
    exit 0
fi
job_id="$(echo "$job" | jq -r '.id')"
echo "[verified-recompute] verified=${conclusion} -> re-running job ${job_id} (run ${run_id})"
gh api -X POST "repos/${REPO}/actions/jobs/${job_id}/rerun" >/dev/null
