#!/usr/bin/env bash
# verified-recompute.sh — RESILIENT-1562
#
# Invoked by .github/workflows/verified-recompute.yml when audit.yml or
# integrations.yml completes. Re-runs ci.yml's `verified` job for the same
# head SHA once audit AND ACP are both terminal, so the verified verdict is a
# function of their terminal state — not of a wall-clock polling window.
#
# Usage: verified-recompute.sh --sha SHA [--repo owner/repo] [--wait-s N] [--dry-run]
# Env GH_TOKEN required. Exit 0 = nothing to do or rerun issued.
set -euo pipefail
REPO="${GH_REPO:-repairman29/chump}"; SHA=""; WAIT_S=1500; DRY=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha) SHA="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --wait-s) WAIT_S="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "[verified-recompute] unknown arg: $1" >&2; exit 3 ;;
    esac
done
[[ -n "$SHA" ]] || { echo "[verified-recompute] --sha required" >&2; exit 3; }

lanes="$("$HERE/poll-cross-workflow-checks.sh" --sha "$SHA" --repo "$REPO" --once \
    --check "audit" --check "ACP protocol smoke test (Zed / JetBrains compatible)")"
if grep -q '=in_progress$' <<<"$lanes"; then
    echo "[verified-recompute] a cross-workflow lane is still pending; its own completion will retrigger"
    exit 0
fi

deadline=$(( $(date +%s) + WAIT_S ))
while true; do
    run="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${SHA}&per_page=20" \
        -q '[.workflow_runs[]] | sort_by(.created_at) | last // empty')"
    [[ -n "$run" ]] || { echo "[verified-recompute] no ci.yml run for $SHA; nothing to do"; exit 0; }
    [[ "$(jq -r .status <<<"$run")" == "completed" ]] && break
    [[ $(date +%s) -ge $deadline ]] && { echo "[verified-recompute] ci run still active after ${WAIT_S}s; leaving it"; exit 0; }
    sleep 20
done
run_id="$(jq -r .id <<<"$run")"
job="$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100" --paginate \
    -q '.jobs[] | select(.name=="verified") | {id, conclusion}' | tail -1)"
[[ -n "$job" ]] || { echo "[verified-recompute] no verified job in run $run_id"; exit 0; }
if [[ "$(jq -r .conclusion <<<"$job")" == "success" ]]; then
    echo "[verified-recompute] verified already success; nothing to do"
    exit 0
fi
job_id="$(jq -r .id <<<"$job")"
echo "[verified-recompute] audit/ACP terminal -> re-running verified job $job_id (run $run_id)"
[[ "$DRY" -eq 1 ]] && exit 0
gh run rerun "$run_id" --repo "$REPO" --job "$job_id"
