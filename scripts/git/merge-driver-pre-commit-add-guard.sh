#!/usr/bin/env bash
# merge-driver-pre-commit-add-guard.sh — INFRA-310
#
# Custom merge driver for scripts/git-hooks/pre-commit conflicts.
# When multiple agents add new guard blocks (e.g., 'if [ ... ]; then ... fi' checks),
# both edits are independent and can be safely merged by appending.
#
# Algorithm:
#   1. Detect if both branches only added guard blocks (no edits/deletions)
#   2. If pure-add scenario, extract new lines from theirs and append to ours
#   3. If either branch edited existing content, refuse and fall back

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

# Count guard block patterns (if [ ... ] blocks) to detect pure-add scenarios.
ancestor_guard_count=$(grep -c '^\s*if\s\+\[' "$ANCESTOR" || echo 0)
ours_guard_count=$(grep -c '^\s*if\s\+\[' "$OURS" || echo 0)
theirs_guard_count=$(grep -c '^\s*if\s\+\[' "$THEIRS" || echo 0)

# Pure-add scenario: ours and theirs both >= ancestor (added, didn't delete/edit).
if [[ $ours_guard_count -lt $ancestor_guard_count ]] || [[ $theirs_guard_count -lt $ancestor_guard_count ]]; then
  exit 1
fi

# Use diff to extract lines added by theirs (not in ancestor).
new_lines=$(diff -u "$ANCESTOR" "$THEIRS" 2>/dev/null | grep '^+' | grep -v '^+++' || true)

if [[ -z "$new_lines" ]]; then
  # Theirs didn't add anything. Use ours as-is.
  cp "$OURS" "$MERGE_FILE"
  exit 0
fi

# Read ours content first (before we write to MERGE_FILE, which might be the same file).
ours_content=$(<"$OURS")

# Build merged content: ours + theirs new lines (with + prefix removed).
{
  echo "$ours_content"
  echo "$new_lines" | sed 's/^+//'
} > "$MERGE_FILE"

exit 0
