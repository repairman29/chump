#!/usr/bin/env bash
# verified-recompute.sh — RESILIENT-1562
# Re-run ci.yml's `verified` job for a SHA once audit/ACP reach a terminal
# state (invoked from verified-recompute.yml on workflow_run completion), so the
# verdict is event-driven instead of depending on a wall-clock poll window.
# Usage: verified-recompute.sh --sha SHA [--repo owner/repo] [--wait-s N] [--interval-s N]
set -euo pipefail
REPO="${GH_REPO:-repairman29/chump}"; SHA=""; WAIT_S=1500; INTERVAL_S=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) SHA="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --wait-s) WAIT_S="$2"; shift 2 ;;
    --interval-s) INTERVAL_S="$2"; shift 2 ;;
    *) echo "[verified-recompute] unknown arg: $1" >&2; exit 3 ;;
  esac
done
[[ -n "$SHA" ]] || { echo "[verified-recompute] --sha required" >&2; exit 3; }
deadline=$(( $(date +%s) + WAIT_S ))
while true; do
  run_id="$(gh run list --repo "$REPO" --workflow ci.yml --commit "$SHA" --limit 1 --json databaseId -q '.[0].databaseId // empty' 2>/dev/null || true)"
  if [[ -n "$run_id" ]]; then
    status="$(gh run view "$run_id" --repo "$REPO" --json status -q .status)"
    if [[ "$status" == "completed" ]]; then
      job="$(gh run view "$run_id" --repo "$REPO" --json jobs -q '[.jobs[]|select(.name=="verified")][0] | "\(.databaseId) \(.conclusion)"')"
      job_id="${job% *}"; concl="${job#* }"
      if [[ "$concl" == "success" ]]; then
        echo "[verified-recompute] verified already success for $SHA — nothing to do"; exit 0
      fi
      echo "[verified-recompute] re-running verified job $job_id (was: $concl) for $SHA"
      gh run rerun "$run_id" --repo "$REPO" --job "$job_id"
      exit 0
    fi
  fi
  if [[ $(date +%s) -ge $deadline ]]; then
    echo "[verified-recompute] ci.yml run for $SHA not completed within ${WAIT_S}s; verified's own poll covers it" >&2
    exit 0
  fi
  sleep "$INTERVAL_S"
done
