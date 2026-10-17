#!/usr/bin/env bash
# ZERO-WASTE-135: Verify all workflow_run and schedule-triggered workflows
# have a concurrency group to prevent duplicate queued runs.

set -euo pipefail

FAILED=0
ALLOWLIST=()

# Workflows that are explicitly allowed to omit concurrency (rare, with good reason)
# Add entries via scripts/ci/workflow-concurrency-exceptions.txt
if [ -f scripts/ci/workflow-concurrency-exceptions.txt ]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    ALLOWLIST+=("$line")
  done < scripts/ci/workflow-concurrency-exceptions.txt
fi

for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$workflow" ] || continue

  # Extract workflow name
  workflow_name=$(basename "$workflow")

  # Check if this workflow is in the allowlist
  in_allowlist=0
  for allow_pattern in "${ALLOWLIST[@]}"; do
    if [[ "$workflow_name" =~ $allow_pattern ]]; then
      in_allowlist=1
      break
    fi
  done

  if [ $in_allowlist -eq 1 ]; then
    continue
  fi

  # Check if workflow has workflow_run or schedule trigger
  has_workflow_run=$(grep -q "^  workflow_run:" "$workflow" && echo 1 || echo 0)
  has_schedule=$(grep -q "^  schedule:" "$workflow" && echo 1 || echo 0)

  if [ $has_workflow_run -eq 0 ] && [ $has_schedule -eq 0 ]; then
    # Not a workflow_run or schedule trigger, skip
    continue
  fi

  # Check if workflow declares a concurrency group
  has_concurrency=$(grep -q "^concurrency:" "$workflow" && echo 1 || echo 0)

  if [ $has_concurrency -eq 0 ]; then
    echo "❌ $workflow_name: workflow_run or schedule trigger detected but no concurrency group declared"
    FAILED=1
  else
    echo "✓ $workflow_name: concurrency group found"
  fi
done

if [ $FAILED -eq 1 ]; then
  echo ""
  echo "ERROR: One or more workflow_run/schedule-triggered workflows are missing a concurrency group."
  echo "This can lead to duplicate queued runs starving other jobs during runner stalls."
  echo ""
  echo "Add a concurrency block like:"
  echo "  concurrency:"
  echo "    group: <workflow-name>-\${{ github.event.workflow_run.head_sha || github.ref }}"
  echo "    cancel-in-progress: true"
  echo ""
  echo "If you have a legitimate reason to omit concurrency, add the workflow name (regex)"
  echo "to scripts/ci/workflow-concurrency-exceptions.txt with a comment explaining why."
  exit 1
fi

exit 0
