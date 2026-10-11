#!/usr/bin/env bash
# verified-recompute.sh — RESILIENT-1562
# Re-run the failed `verified` job of ci.yml run(s) for a SHA after audit/ACP
# reached a terminal state. Waits on the CI run's own completion (event state,
# not a lane wall-clock window), since GitHub only reruns completed runs.
# Usage: verified-recompute.sh SHA   (env: GH_REPO, GH_TOKEN; MAX_WAIT_S default 900)
set -euo pipefail
SHA="${1:?usage: verified-recompute.sh SHA}"
REPO="${GH_REPO:?GH_REPO required}"
MAX_WAIT_S="${MAX_WAIT_S:-900}"
deadline=$(( $(date +%s) + MAX_WAIT_S ))

runs="$(gh run list --repo "$REPO" --workflow ci.yml --commit "$SHA" --json databaseId,status,event -q '.[]|[.databaseId,.status]|@tsv')"
[[ -z "$runs" ]] && { echo "no ci.yml run for $SHA"; exit 0; }

while IFS=$'\t' read -r id _; do
    while true; do
        view="$(gh run view "$id" --repo "$REPO" --json status,jobs)"
        status="$(jq -r .status <<<"$view")"
        if [[ "$status" == "completed" ]]; then break; fi
        if [[ $(date +%s) -ge $deadline ]]; then echo "run $id still $status at deadline; skipping"; continue 2; fi
        sleep 10
    done
    vc="$(jq -r '[.jobs[]|select(.name=="verified")][0].conclusion // "none"' <<<"$view")"
    if [[ "$vc" == "success" || "$vc" == "none" || "$vc" == "skipped" ]]; then
        echo "run $id: verified=$vc, nothing to do"; continue
    fi
    echo "run $id: verified=$vc -> rerunning failed jobs"
    gh run rerun "$id" --repo "$REPO" --failed || echo "::warning::rerun of $id failed (non-fatal)"
done <<<"$runs"
