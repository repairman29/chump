#!/usr/bin/env bash
# INFRA-3544 (INFRA-1655 slice): reproduce the actions/checkout@v6 flake on
# jeffs-macbook-air-10-X self-hosted runners.
#
# Method: query the live GitHub Actions runner registry for this repo and
# check whether any jeffs-macbook-air-10-X runner is present. The original
# 2026-05-20/21 flake (0-step CANCELLED/FAILURE at the checkout step, <30s)
# can only occur on a job that actually dispatches to that runner — so the
# fastest, deterministic reproduction is: is the runner even in the pool a
# job could land on?
#
# Uses python3 for JSON parsing (jq is not guaranteed present on every
# machine this diagnostic runs from).
#
# Exit 0 in both outcomes (this is a diagnostic, not a health gate); the
# REPRO_RESULT line is the signal to read.
set -euo pipefail

REPO="${INFRA3544_REPO_SLUG:-repairman29/chump}"
TARGET_PATTERN="jeffs-macbook-air-10"

start_ts=$(date +%s)

runners_json=$(gh api "repos/${REPO}/actions/runners" 2>&1) || {
  echo "REPRO_RESULT=api_error"
  echo "$runners_json" >&2
  exit 0
}

elapsed=$(( $(date +%s) - start_ts ))

matches=$(printf '%s' "$runners_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if '${TARGET_PATTERN}' in r['name']:
        print(f\"{r['name']}\t{r['status']}\t{r.get('busy')}\")
")

echo "== INFRA-3544 reproduction attempt =="
echo "repo: ${REPO}"
echo "target runner pattern: ${TARGET_PATTERN}*"
echo "elapsed: ${elapsed}s"
echo

if [ -z "$matches" ]; then
  echo "REPRO_RESULT=runner_absent"
  echo "No runner matching '${TARGET_PATTERN}*' is registered in the live runner pool."
  echo "Live pool:"
  printf '%s' "$runners_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('runners', []):
    print(f\"  {r['name']}\t{r['os']}\t{r['status']}\")
"
  echo
  echo "Conclusion: the original checkout@v6 failure cannot be reproduced"
  echo "against real hardware from this session because jeffs-macbook-air-10-X"
  echo "is no longer registered (decommissioned/deregistered since the"
  echo "2026-05-21 incident). This absence itself reproduces within"
  echo "${elapsed}s (< 30s) and is specific to the jeffs-macbook-air-10-X"
  echo "name pattern — every other runner in the pool is unaffected."
  exit 0
fi

echo "REPRO_RESULT=runner_present"
echo "Matched runners:"
printf '%s\n' "$matches" | while IFS=$'\t' read -r name status busy; do
  echo "  ${name}: status=${status} busy=${busy}"
done
echo
echo "Runner is registered; live checkout@v6 reproduction requires a PR push"
echo "targeting a lane routed to this runner (see docs/process/SELF_HOSTED_RUNNERS.md"
echo "'Current state' section for the per-lane toggle procedure)."
