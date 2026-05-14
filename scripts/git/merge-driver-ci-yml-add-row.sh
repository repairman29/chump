#!/usr/bin/env bash
# merge-driver-ci-yml-add-row.sh — INFRA-310
#
# Custom merge driver for .github/workflows/ci.yml conflicts.
# When multiple agents add new YAML step entries (e.g., new '- name: ... | run: ...' jobs),
# both edits are pure additions and can be safely merged by appending.
#
# Algorithm:
#   1. Detect if BOTH branches only appended steps after a common prefix
#      (pure-append scenario: first N lines of ours/theirs == ancestor exactly)
#   2. If yes, append theirs' tail to ours
#   3. If either branch edited existing steps or inserted in the middle, refuse (exit 1)
#
# Bugs fixed (INFRA-1205):
#   - grep -c exits 1 on 0 matches; "|| echo 0" inside $() also fires, producing
#     "0\n0" in the variable and "[[ 0\n0 -lt N ]]" syntax error.  Fixed by
#     putting the fallback assignment outside the subshell: $(…) || var=0
#   - grep lacked -E; "(name|uses)" was treated as a BRE literal, never matching.
#   - Naive "diff | grep '^+'" extracted ALL added lines anywhere in theirs and
#     appended them to the end of ours, corrupting files when theirs had edits
#     outside the tail (path-filter additions, duplicate if: lines, etc.).
#     Fixed: verify pure-append by comparing head-N of ours/theirs to ancestor,
#     then take only the tail beyond ancestor line-count.

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

ancestor_lines=$(wc -l < "$ANCESTOR")
ours_lines=$(wc -l < "$OURS")
theirs_lines=$(wc -l < "$THEIRS")

# Both branches must have at least as many lines as ancestor (no deletions).
if [[ $ours_lines -lt $ancestor_lines ]] || [[ $theirs_lines -lt $ancestor_lines ]]; then
  exit 1
fi

# Pure-append check: the first ancestor_lines of ours and theirs must be
# identical to ancestor.  Any insertion or edit in the shared prefix means we
# can't safely auto-merge — fall back to the standard 3-way merge (exit 1).
if ! diff -q <(head -n "$ancestor_lines" "$OURS")   "$ANCESTOR" > /dev/null 2>&1; then
  exit 1
fi
if ! diff -q <(head -n "$ancestor_lines" "$THEIRS") "$ANCESTOR" > /dev/null 2>&1; then
  exit 1
fi

# Extract the lines theirs appended beyond the shared ancestor prefix.
theirs_tail=$(tail -n +"$((ancestor_lines + 1))" "$THEIRS")

if [[ -z "$theirs_tail" ]]; then
  # Theirs appended nothing; keep ours as-is.
  exit 0
fi

# Safe to merge: append theirs' new steps to ours.
printf '%s\n%s\n' "$(cat "$OURS")" "$theirs_tail" > "$MERGE_FILE"

exit 0
