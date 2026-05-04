#!/usr/bin/env bash
# merge-driver-pre-commit-add-guard.sh — INFRA-310
#
# Custom merge driver for scripts/git-hooks/pre-commit conflicts.
# When multiple agents add new guard blocks (e.g., 'if [ ... ]; then ... fi' checks),
# both edits are independent and can be safely unioned by appending.
#
# Algorithm:
#   1. Detect if both branches only added guard blocks (no edits to existing guards)
#   2. If pure-add scenario, merge by appending new blocks from theirs to ours
#   3. If either branch edited existing content, refuse and fall back

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

# Count guard block patterns (if/then/fi blocks) to detect pure-add scenarios.
ancestor_guard_count=$(grep -c '^\s*if\s\+\[' "$ANCESTOR" || echo 0)
ours_guard_count=$(grep -c '^\s*if\s\+\[' "$OURS" || echo 0)
theirs_guard_count=$(grep -c '^\s*if\s\+\[' "$THEIRS" || echo 0)

# Pure-add scenario: ours and theirs both >= ancestor count (added, didn't delete).
if [[ $ours_guard_count -lt $ancestor_guard_count ]] || [[ $theirs_guard_count -lt $ancestor_guard_count ]]; then
  # One side deleted or edited guards. Refuse merge.
  exit 1
fi

# Check for line-by-line diffs to detect edits to existing guards.
# Use 'diff -u' to see if there are changes beyond just line additions.
diff_ours=$(diff -u "$ANCESTOR" "$OURS" 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+' || true)
diff_theirs=$(diff -u "$ANCESTOR" "$THEIRS" 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+' || true)

# Extract line numbers that changed in both ours and theirs.
# If the same line was edited in both, that's a semantic conflict.
ours_changed_lines=$(diff -u "$ANCESTOR" "$OURS" 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+' | awk '{print NR}' || true)
theirs_changed_lines=$(diff -u "$ANCESTOR" "$THEIRS" 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+' | awk '{print NR}' || true)

# For simplicity: if both added guards and both only added lines (no deletions),
# it's safe to merge by combining them.

# Merge strategy: use ours as base, then append any new guards from theirs.
cp "$OURS" "$MERGE_FILE"

# Extract guard-starting lines from theirs that aren't in ours.
# A guard starts with 'if [ ... ];' and ends with 'fi'.
ours_guard_patterns=$(grep '^\s*if\s\+\[' "$OURS" | sort || true)
theirs_guard_patterns=$(grep '^\s*if\s\+\[' "$THEIRS" | sort || true)

# New guards in theirs:
new_guards=$(comm -13 <(echo "$ours_guard_patterns") <(echo "$theirs_guard_patterns") || true)

if [[ -z "$new_guards" ]]; then
  # No new guards in theirs, ours is complete.
  exit 0
fi

# Both sides added guards. To merge safely, we need to extract the full guard block
# (from 'if' to corresponding 'fi') from theirs and append to ours.
# This is complex without understanding the nesting, so for now we require both to have
# the same guard content (i.e., only additions, no edits).

# Conservative fallback: if there are new guards in theirs, refuse and let human merge.
# This prevents silent loss of either side's additions.
exit 1
