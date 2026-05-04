#!/usr/bin/env bash
# merge-driver-ci-yml-add-row.sh — INFRA-310
#
# Custom merge driver for .github/workflows/ci.yml conflicts.
# When multiple agents add new YAML step entries (e.g., new '- name: ... | run: ...' jobs),
# both edits are pure additions and can be safely merged by appending.
#
# Algorithm:
#   1. Detect if both branches only added steps (pure-add scenario)
#   2. If yes, extract new steps from theirs and append to ours
#   3. If either branch edited existing steps, refuse the merge

set -euo pipefail

ANCESTOR="$1"
OURS="$2"
THEIRS="$3"
# CONFLICT_MARKER_LEN="$4"  # not used
MERGE_FILE="$OURS"  # Modify ours in-place

# Sanity checks
if [[ ! -f "$ANCESTOR" ]] || [[ ! -f "$OURS" ]] || [[ ! -f "$THEIRS" ]]; then
  exit 1
fi

# Count step/job entries (lines starting with '- name:' or '- uses:').
ancestor_count=$(grep -c '^\s*-\s\+(name|uses):' "$ANCESTOR" || echo 0)
ours_count=$(grep -c '^\s*-\s\+(name|uses):' "$OURS" || echo 0)
theirs_count=$(grep -c '^\s*-\s\+(name|uses):' "$THEIRS" || echo 0)

# Pure-add scenario: ours and theirs both >= ancestor (added, didn't delete/edit).
if [[ $ours_count -lt $ancestor_count ]] || [[ $theirs_count -lt $ancestor_count ]]; then
  exit 1
fi

# Read ours content first (before truncating MERGE_FILE).
ours_content=$(<"$OURS")

# Extract new lines from theirs (not in ancestor).
new_lines=$(diff -u "$ANCESTOR" "$THEIRS" 2>/dev/null | grep '^+' | grep -v '^+++' || true)

if [[ -z "$new_lines" ]]; then
  # Theirs didn't add anything new. Use ours as-is.
  echo "$ours_content" > "$MERGE_FILE"
  exit 0
fi

# Append theirs' new lines to ours.
{
  echo "$ours_content"
  echo "$new_lines" | sed 's/^+//'
} > "$MERGE_FILE"

exit 0
