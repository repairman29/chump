#!/bin/bash
# CREDIBLE-1491: CI test to ensure exactly one code path writes gaps.status='done' or 'shipped'
# The ONLY allowed place is inside GapStore::perform_gap_closure

set -euo pipefail

echo "CREDIBLE-1491: Scanning for direct status='done' writers in production code..."

# Get raw list of all UPDATE statements
raw_matches=$(grep -rn "UPDATE gaps SET.*status.*'done'\|UPDATE gaps SET.*status.*'shipped'" \
  crates/ scripts/ \
  --include="*.rs" --include="*.sh" || true)

bad_matches=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  
  file=$(echo "$line" | cut -d: -f1)
  line_num=$(echo "$line" | cut -d: -f2)
  
  # The ONLY allowed location: perform_gap_closure method in lib.rs
  if [ "$file" = "crates/chump-gap-store/src/lib.rs" ]; then
    # Check if inside perform_gap_closure (around lines 3086-3100)
    if sed -n "3070,3110p" "$file" | grep -q "$(echo "$line" | cut -d: -f3-)"; then
      continue
    fi
  fi
  
  # Skip test-only accessors - check within 5 lines before the UPDATE
  if sed -n "$((line_num-5)),$((line_num))p" "$file" 2>/dev/null | grep -q "conn_for_test\|conn_for_sync"; then
    continue
  fi
  
  # For .rs files, skip if inside a #[test] block
  if echo "$file" | grep -q "\.rs$"; then
    if sed -n "$((line_num-30)),$((line_num))p" "$file" 2>/dev/null | grep -q "#\[test\]"; then
      continue
    fi
  fi
  
  # For .sh files, skip test scripts
  if echo "$line" | grep -q "scripts/ci/test-"; then
    continue
  fi
  
  # This is a bad match
  bad_matches="$bad_matches$line
"
done <<< "$raw_matches"

if [ -n "$bad_matches" ]; then
  echo "FAIL: Found production code paths that write status='done/shipped' outside perform_gap_closure:"
  echo "$bad_matches"
  exit 1
fi

echo "PASS: All status='done/shipped' transitions route through perform_gap_closure"
