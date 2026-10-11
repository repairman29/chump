#!/usr/bin/env bash
# verified-recompute.sh — RESILIENT-1562
#
# Event-driven recompute of ci.yml's `verified` aggregator. Invoked from
# .github/workflows/verified-recompute.yml when audit.yml / integrations.yml
# (the cross-workflow lanes `verified` polls) complete. If the head commit's
# ci.yml run is already finished and its `verified` job is not green, re-run
# ONLY that job so its verdict tracks audit/ACP's terminal state rather than
# a fixed wall-clock poll window. If the ci.yml run is still in progress,
# `verified` is still polling and will observe the terminal state itself.
#
# Usage: verified-recompute.sh --sha SHA [--repo owner/repo] [--dry-run]
# Env:   GH_TOKEN. Exit 0 always on "nothing to do"; prints the decision.
set -euo pipefail

REPO="${GH_REPO:-repairman29/chump}"
SHA=""
DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha) SHA="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "[verified-recompute] unknown arg: $1" >&2; exit 3 ;;
    esac
done
[[ -n "$SHA" ]] || { echo "[verified-recompute] --sha required" >&2; exit 3; }

run="$(gh run list --repo "$REPO" --workflow ci.yml --commit "$SHA" --limit 1 \
    --json databaseId,status 2>/dev/null | jq -c '.[0] // empty')"
if [[ -z "$run" ]]; then
    echo "[verified-recompute] no ci.yml run for $SHA — nothing to do"; exit 0
fi
run_id="$(jq -r '.databaseId' <<<"$run")"
status="$(jq -r '.status' <<<"$run")"
if [[ "$status" != "completed" ]]; then
    echo "[verified-recompute] ci.yml run $run_id is $status — verified will observe terminal state itself"; exit 0
fi

job="$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs" --paginate -q '.jobs[]' 2>/dev/null \
    | jq -sc '[.[] | select(.name == "verified")] | last // empty')"
if [[ -z "$job" ]]; then
    echo "[verified-recompute] run $run_id has no verified job — nothing to do"; exit 0
fi
job_id="$(jq -r '.id' <<<"$job")"
concl="$(jq -r '.conclusion // ""' <<<"$job")"
if [[ "$concl" == "success" ]]; then
    echo "[verified-recompute] verified already success on run $run_id — nothing to do"; exit 0
fi

echo "[verified-recompute] re-running verified job $job_id (was '$concl') on run $run_id"
if [[ "$DRY" -eq 1 ]]; then exit 0; fi
gh run rerun --repo "$REPO" "$run_id" --job "$job_id"
