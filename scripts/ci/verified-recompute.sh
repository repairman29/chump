#!/usr/bin/env bash
# verified-recompute.sh — RESILIENT-1562
#
# Called from verified-recompute.yml when Audit / integrations completes.
# Finds the ci.yml run for --sha; if its `verified` job concluded
# failure/cancelled while audit + ACP smoke are now both terminal, re-runs
# just that job so the verdict tracks audit/ACP terminal state rather than
# the in-job poll window.
#
# Usage: verified-recompute.sh --sha SHA [--repo owner/repo] [--dry-run]

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

here="$(cd "$(dirname "$0")" && pwd)"
lanes="$(bash "$here/poll-cross-workflow-checks.sh" --repo "$REPO" --sha "$SHA" \
    --check "audit" --check "ACP protocol smoke test (Zed / JetBrains compatible)" \
    --timeout-s 0 --interval-s 1)"
echo "$lanes"
# Only recompute once both lanes are terminal (in_progress => a later completion will retrigger).
if grep -q '=in_progress$' <<<"$lanes"; then
    echo "[verified-recompute] audit/ACP not terminal yet; nothing to do"
    exit 0
fi

run_id="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${SHA}&event=pull_request&per_page=1" -q '.workflow_runs[0].id // empty')"
[[ -n "$run_id" ]] || { echo "[verified-recompute] no ci.yml run for $SHA"; exit 0; }

job="$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100" --paginate \
    -q '.jobs[] | select(.name=="verified") | "\(.id) \(.status) \(.conclusion // "")"' | tail -1)"
read -r job_id status conclusion <<<"$job"
[[ -n "${job_id:-}" ]] || { echo "[verified-recompute] no verified job in run $run_id"; exit 0; }
if [[ "$status" != "completed" ]]; then
    echo "[verified-recompute] verified still $status; it will poll the now-terminal lanes itself"
    exit 0
fi
if [[ "$conclusion" == "success" ]]; then
    echo "[verified-recompute] verified already green"
    exit 0
fi
echo "[verified-recompute] re-running verified job $job_id (was $conclusion)"
[[ "$DRY" -eq 1 ]] || gh api -X POST "repos/${REPO}/actions/jobs/${job_id}/rerun" >/dev/null
