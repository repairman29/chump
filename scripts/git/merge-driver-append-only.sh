#!/usr/bin/env bash
# merge-driver-append-only.sh — INFRA-1389
#
# Generic pure-append merge driver for files where concurrent PRs exclusively
# add new entries at the end (never edit the shared prefix).
#
# Registered for:
#   Cargo.toml       — new [dependencies] / [[bin]] entries
#   web/v2/app.js    — new component class definitions + VIEWS entries
#   src/main.rs      — new route arms / handler registrations
#
# Algorithm (same as ci-yml-add-row but without YAML step-body validation):
#   1. Verify both ours and theirs start with ancestor verbatim (pure-append check).
#      Any insertion or edit in the shared prefix → exit 1 (fall back to 3-way).
#   2. Extract theirs' tail beyond ancestor length.
#   3. Deduplicate: remove any theirs-tail lines that already appear in ours
#      (handles the case where both branches added the same dep/class).
#   4. Append deduplicated tail to ours.
#
# Deduplication is line-granular to handle Cargo.toml dependencies where two
# PRs independently add the exact same `serde = "1"` line.
#
# Callers: git merge / rebase when .gitattributes assigns `merge=<driver-name>`
# Arguments (git merge driver convention):
#   $1 = %O  ancestor temp file
#   $2 = %A  ours temp file  (driver modifies this in-place)
#   $3 = %B  theirs temp file
#   $4 = %L  conflict-marker length (unused)

set -euo pipefail

ANCESTOR="$1"
OURS="$2"
THEIRS="$3"

if [[ ! -f "$ANCESTOR" ]] || [[ ! -f "$OURS" ]] || [[ ! -f "$THEIRS" ]]; then
  exit 1
fi

ancestor_lines=$(wc -l < "$ANCESTOR")
ours_lines=$(wc -l < "$OURS")
theirs_lines=$(wc -l < "$THEIRS")

# Both branches must only have grown (no deletions from the ancestor).
if [[ $ours_lines -lt $ancestor_lines ]] || [[ $theirs_lines -lt $ancestor_lines ]]; then
  exit 1
fi

# Pure-append check: first ancestor_lines of ours and theirs must match ancestor.
if ! diff -q <(head -n "$ancestor_lines" "$OURS")   "$ANCESTOR" > /dev/null 2>&1; then
  exit 1
fi
if ! diff -q <(head -n "$ancestor_lines" "$THEIRS") "$ANCESTOR" > /dev/null 2>&1; then
  exit 1
fi

# Extract the lines theirs appended beyond the shared ancestor.
theirs_tail=$(tail -n +"$((ancestor_lines + 1))" "$THEIRS")

if [[ -z "$theirs_tail" ]]; then
  # Theirs appended nothing; ours is already correct.
  exit 0
fi

# Extract lines ours appended beyond the shared ancestor.
ours_tail="$(tail -n +"$((ancestor_lines + 1))" "$OURS")"

# Deduplicate: skip theirs-tail lines already in ours-tail.
# This prevents double-registration when both branches independently added
# the same entry (e.g., two PRs each adding `serde = "1"` to Cargo.toml).
#
# INFRA-1526 fix: compare against ours_tail ONLY, not the full $OURS file.
# The old code (`grep -qxF "$line" "$OURS"`) matched common structural lines
# (`}`, blank lines, etc.) against the shared ancestor prefix in $OURS,
# silently dropping them from theirs_tail and corrupting the merged result.
# Example: PR #2216 lost a 173-line src/main.rs block this way.
ordered_unique_tail=""
while IFS= read -r line; do
  if [[ -n "$ours_tail" ]] && grep -qxF -- "$line" <<< "$ours_tail" 2>/dev/null; then
    : # already in ours additions — skip
  else
    ordered_unique_tail="${ordered_unique_tail}${line}"$'\n'
  fi
done <<< "$theirs_tail"

# Remove trailing newline.
ordered_unique_tail="${ordered_unique_tail%$'\n'}"

if [[ -z "$ordered_unique_tail" ]]; then
  # All of theirs' additions were already in ours (e.g., both branches added
  # the exact same dependency); ours is correct as-is.
  exit 0
fi

# Append theirs' unique additions to ours.
printf '%s\n%s\n' "$(cat "$OURS")" "$ordered_unique_tail" > "$OURS"

exit 0
