#!/bin/bash
# scripts/coord/pr-revert.sh — PRODUCT-086: Create a revert PR for a merged PR.
#
# Usage: pr-revert.sh <PR_NUMBER>
#
# Since GitHub CLI doesn't natively support "gh pr revert", we manually:
# 1. Fetch the PR metadata (to get the merge commit SHA)
# 2. Create a new branch from main
# 3. Run git revert <merge-commit-SHA>
# 4. Push the branch
# 5. Create a new PR with the revert commit

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <PR_NUMBER>" >&2
  exit 1
fi

PR_NUM="$1"

# Get PR metadata: merged_by, mergeCommitSha, baseRefName
PR_DATA=$(gh pr view "$PR_NUM" --json mergeCommitSha,baseRefName,title,number)
MERGE_COMMIT=$(echo "$PR_DATA" | jq -r '.mergeCommitSha')
BASE_BRANCH=$(echo "$PR_DATA" | jq -r '.baseRefName')
ORIGINAL_TITLE=$(echo "$PR_DATA" | jq -r '.title')

if [[ -z "$MERGE_COMMIT" ]]; then
  echo "Error: PR #$PR_NUM is not merged (no mergeCommitSha)" >&2
  exit 1
fi

# Create a revert branch
REVERT_BRANCH="revert-pr-${PR_NUM}-$(date +%s)"
git fetch origin "$BASE_BRANCH"
git checkout -b "$REVERT_BRANCH" "origin/$BASE_BRANCH"

# Revert the merge commit
git revert -m 1 "$MERGE_COMMIT" --no-edit

# Push the branch
git push -u origin "$REVERT_BRANCH"

# Create a new PR for the revert
gh pr create \
  --base "$BASE_BRANCH" \
  --head "$REVERT_BRANCH" \
  --title "Revert \"$ORIGINAL_TITLE\" (#$PR_NUM)" \
  --body "This PR reverts PR #$PR_NUM. Created automatically via PRODUCT-086 PWA action panel."
