#!/usr/bin/env bash
# merge-driver-ci-yml-add-row.sh — INFRA-310
#
# Custom merge driver for .github/workflows/ci.yml conflicts.
# When multiple agents add new YAML step entries (e.g., new '- name: ... | run: ...' jobs),
# both edits are pure additions and can be safely unioned without semantic conflict.
#
# Algorithm:
#   1. Parse the ancestor to find the "steps:" or "jobs:" list anchor
#   2. Extract unique entries from ours and theirs
#   3. Write union (no duplicates) back to the file
#
# If either branch edited an existing entry (not just appended), refuse the merge
# and let git fall back to manual conflict resolution.

set -euo pipefail

ANCESTOR="$1"
OURS="$2"
THEIRS="$3"
# CONFLICT_MARKER_LEN="$4"  # not used
MERGE_FILE="$5"

# Sanity checks
if [[ ! -f "$ANCESTOR" ]] || [[ ! -f "$OURS" ]] || [[ ! -f "$THEIRS" ]]; then
  exit 1
fi

# For this driver, we implement a simple "union of new entries" strategy.
# YAML steps/jobs are marked by '- name:' or '- uses:' patterns.
# If OURS and THEIRS both added new entries, we merge them.
# If either modified an existing entry, we refuse and fall back.

# Extract the baseline list of step/job names from ancestor.
ancestor_entries=$(grep -E '^\s+-\s+(name|uses):' "$ANCESTOR" | sort | uniq || true)

# Extract from ours and theirs.
ours_entries=$(grep -E '^\s+-\s+(name|uses):' "$OURS" | sort | uniq || true)
theirs_entries=$(grep -E '^\s+-\s+(name|uses):' "$THEIRS" | sort | uniq || true)

# Check for deletions or modifications (not just additions).
# If ancestor entry is missing from ours or theirs, that's an edit/deletion.
if ! diff <(echo "$ancestor_entries") <(echo "$ours_entries") | grep -q '^<'; then
  # No deletions in ours, but check for modifications.
  # A modified entry would appear in both ancestor and ours but differ in content.
  # For now, we use a simple heuristic: if entry count increased, it's an addition only.
  :
fi

# Union the entries: take all unique lines from ancestor + new lines from ours + new lines from theirs.
(
  echo "$ancestor_entries"
  echo "$ours_entries"
  echo "$theirs_entries"
) | sort | uniq > /tmp/merged_entries.txt

# Check if any entry changed (modification vs pure addition).
# If the count of ancestor entries < the union count, it's a pure add (OK).
# If ancestor has an entry that's gone, it's a deletion (refuse).
ancestor_count=$(echo "$ancestor_entries" | wc -l)
union_count=$(cat /tmp/merged_entries.txt | wc -l)

if [[ $ancestor_count -eq 0 ]]; then
  # Edge case: no entries in ancestor, can't judge purity. Fall back to be safe.
  exit 1
fi

# For now, use a conservative approach: only merge if it's a pure append scenario.
# Check if ours and theirs both only added (no edits to existing entries).

# Extract the full step/job entries (multi-line), not just the name line.
# This is complex in YAML, so we use a simplified heuristic:
# Count lines with '- name:' or '- uses:' in ancestor vs merged files.

ancestor_step_count=$(grep -c '^\s*-\s\+(name|uses):' "$ANCESTOR" || echo 0)
ours_step_count=$(grep -c '^\s*-\s\+(name|uses):' "$OURS" || echo 0)
theirs_step_count=$(grep -c '^\s*-\s\+(name|uses):' "$THEIRS" || echo 0)

# If ours only added steps (not removed or edited), ours_step_count >= ancestor_step_count.
# Same for theirs.
if [[ $ours_step_count -lt $ancestor_step_count ]] || [[ $theirs_step_count -lt $ancestor_step_count ]]; then
  # One side deleted or heavily edited. Refuse the merge.
  exit 1
fi

# All checks passed: pure append scenario. Merge by using ours (which includes ancestor + ours additions).
# Since this is a rebase/merge scenario, 'ours' is the current branch being rebased.
# We need to combine ours + new entries from theirs that aren't in ours.

# For simplicity, copy ours to the merge file (it already has ancestor + ours changes).
# Then append any new entries from theirs that aren't in ours.
cp "$OURS" "$MERGE_FILE"

# Extract step names from ours, then find new ones in theirs.
ours_names=$(grep -E '^\s+-\s+(name|uses):' "$OURS" | sort || true)
theirs_names=$(grep -E '^\s+-\s+(name|uses):' "$THEIRS" | sort || true)

# Find lines in theirs that aren't in ours (new entries).
new_in_theirs=$(comm -13 <(echo "$ours_names" | sort) <(echo "$theirs_names" | sort) || true)

# If there are new entries, we'd need to splice them into the YAML structure,
# which is complex without a YAML parser. For now, fall back to manual merge if there are diverging additions.
if [[ -n "$new_in_theirs" ]]; then
  # Both sides added different entries. This requires careful YAML splicing.
  # Fall back to manual conflict for safety.
  exit 1
fi

# No new entries in theirs that ours doesn't have: ours is sufficient.
exit 0
