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
#   - grep -c exits 1 on 0 matches; "|| true" inside $() also fires, producing
#     "0\n0" in the variable and "[[ 0\n0 -lt N ]]" syntax error.  Fixed by
#     putting the fallback assignment outside the subshell: $(…) || var=0
#   - grep lacked -E; "(name|uses)" was treated as a BRE literal, never matching.
#   - Naive "diff | grep '^+'" extracted ALL added lines anywhere in theirs and
#     appended them to the end of ours, corrupting files when theirs had edits
#     outside the tail (path-filter additions, duplicate if: lines, etc.).
#     Fixed: verify pure-append by comparing head-N of ours/theirs to ancestor,
#     then take only the tail beyond ancestor line-count.
#
# Bug fixed (INFRA-1199):
#   - Driver could append a '- name:' step header without a 'run:' or 'uses:' body
#     if theirs_tail contained an incomplete step. GitHub Actions rejects such files
#     outright — zero CI jobs run. Fixed: validate_step_bodies() checks every
#     '- name:' in theirs_tail is followed by 'run:' or 'uses:' before writing.
#
# INFRA-1482: last-resort YAML-aware fallback.
#   - All the strategies above are line/text heuristics; the reported failure
#     (rebase of #2088) was an INTERLEAVED addition — ours inserts a step
#     between two steps that theirs also added to the same job — which none
#     of the line-based paths can safely resolve. Before giving up (rc=1),
#     try scripts/git/ci-yml-yaml-merge.py: it parses ours/theirs/ancestor as
#     YAML (line-accurate, no re-dump) and unions each shared job's `steps:`
#     keyed by step name, anchored to base position. If it also can't
#     resolve, emit kind=merge_driver_fallback so operators can measure how
#     often manual conflict resolution is still needed, then exit 1.

set -euo pipefail

ANCESTOR="$1"
OURS="$2"
THEIRS="$3"
# CONFLICT_MARKER_LEN="$4"  # not used
MERGE_FILE="$OURS"  # Modify ours in-place

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_FALLBACK="$SCRIPT_DIR/ci-yml-yaml-merge.py"

_emit_ambient() {
  local kind="$1" reason="$2"
  local repo amb
  repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  [[ -z "$repo" ]] && return 0
  amb="${CHUMP_AMBIENT_LOG:-$repo/.chump-locks/ambient.jsonl}"
  [[ -w "$(dirname "$amb")" ]] 2>/dev/null || return 0
  printf '{"ts":"%s","kind":"%s","ours":"%s","theirs":"%s","reason":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$OURS" "$THEIRS" "$reason" \
    >> "$amb" 2>/dev/null || true
}

# Last resort before giving up: try the YAML-aware step-union merge. On
# success it rewrites $OURS in place and we exit 0. On failure, emit the
# fallback-measurement event and exit 1 (unchanged historical behavior).
give_up() {
  local reason="$1"
  if [[ -x "$YAML_FALLBACK" || -f "$YAML_FALLBACK" ]] && command -v python3 > /dev/null 2>&1; then
    if python3 "$YAML_FALLBACK" "$ANCESTOR" "$OURS" "$THEIRS" 2>/dev/null; then
      exit 0
    fi
  fi
  _emit_ambient "merge_driver_fallback" "$reason"
  exit 1
}

# Sanity checks
if [[ ! -f "$ANCESTOR" ]] || [[ ! -f "$OURS" ]] || [[ ! -f "$THEIRS" ]]; then
  exit 1
fi

ancestor_lines=$(wc -l < "$ANCESTOR")
ours_lines=$(wc -l < "$OURS")
theirs_lines=$(wc -l < "$THEIRS")

# Both branches must have at least as many lines as ancestor (no deletions).
if [[ $ours_lines -lt $ancestor_lines ]] || [[ $theirs_lines -lt $ancestor_lines ]]; then
  give_up "line_count_shrunk"
fi

# Pure-append check: the first ancestor_lines of ours and theirs must be
# identical to ancestor.  Track ours and theirs separately so the INFRA-1490
# fallback can distinguish "both sides edited the shared prefix" (safe to
# patch) from "only theirs edited the shared prefix" (unsafe — applying
# theirs' mid-file diff to a pure-append ours would corrupt ours).
_pure_ours=1
_pure_theirs=1
if ! diff -q <(head -n "$ancestor_lines" "$OURS")   "$ANCESTOR" > /dev/null 2>&1; then
  _pure_ours=0
fi
if ! diff -q <(head -n "$ancestor_lines" "$THEIRS") "$ANCESTOR" > /dev/null 2>&1; then
  _pure_theirs=0
fi
_pure_append=$(( _pure_ours & _pure_theirs ))

# If ours is a pure append but theirs has mid-file edits, exit 1 and let
# git's 3-way merge handle it — applying theirs' diff to ours would insert
# theirs' mid-file content into ours (corruption, INFRA-1205 regression).
if [[ $_pure_ours -eq 1 && $_pure_theirs -eq 0 ]]; then
  give_up "theirs_edited_shared_prefix"
fi

if [[ $_pure_append -eq 0 ]]; then
  # ── INFRA-1490: patch-based fallback for mid-file row additions ─────────
  # 12 of my own DIRTY PRs on 2026-05-16T04:30 had ci.yml conflicts because
  # everyone was adding test-rows in the AUDIT-JOB section (mid-file). The
  # pure-append driver above refused, dropping to 3-way merge which produced
  # markers. This fallback: if `diff ancestor theirs` is an ADD-ONLY diff
  # (no deletes), try applying it to ours with fuzz so context-line offsets
  # are absorbed. patch(1) handles the common case where ours added rows
  # before theirs' add point or after it.
  _diff_theirs=$(mktemp)
  diff -u "$ANCESTOR" "$THEIRS" > "$_diff_theirs" 2>/dev/null || true
  # Count +/- lines (excluding the ---/+++ headers).
  _adds=$(grep -cE '^\+[^+]' "$_diff_theirs" 2>/dev/null) || _adds=0
  _dels=$(grep -cE '^-[^-]' "$_diff_theirs" 2>/dev/null) || _dels=0
  if [[ "$_adds" -eq 0 ]]; then
    # Theirs added nothing — keep ours, success.
    rm -f "$_diff_theirs"
    exit 0
  fi
  if [[ "$_dels" -gt 0 ]]; then
    # Theirs has real edits/deletes; can't safely patch.
    rm -f "$_diff_theirs"
    give_up "theirs_has_deletes"
  fi
  # ADD-ONLY diff. Try two strategies in order:
  #   (a) patch --fuzz=3 — handles case where ours+theirs added at different
  #       anchor points (line offsets absorbed by fuzz)
  #   (b) git merge-file --union — handles case where ours+theirs added at
  #       the SAME anchor point (concatenate both sides at the conflict region)
  if patch --silent --fuzz=3 --no-backup-if-mismatch "$OURS" < "$_diff_theirs" 2>/dev/null; then
    _mode="patch_fuzz3"
  elif git merge-file --union "$OURS" "$ANCESTOR" "$THEIRS" 2>/dev/null; then
    # --union returned non-zero on conflicts but wrote the union output;
    # capture EXIT here in a way that survives either 0 or merge-conflict rc.
    _mode="union"
  else
    # git merge-file --union ALSO returned non-zero (true failure).
    rm -f "$_diff_theirs"
    give_up "patch_and_union_both_failed"
  fi
  _repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ -n "$_repo" ]]; then
    _amb="${CHUMP_AMBIENT_LOG:-$_repo/.chump-locks/ambient.jsonl}"
    if [[ -w "$(dirname "$_amb")" ]] 2>/dev/null; then
      printf '{"ts":"%s","kind":"ci_yml_row_add_merged","ours":"%s","theirs":"%s","mode":"%s","adds":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OURS" "$THEIRS" "$_mode" "$_adds" \
        >> "$_amb" 2>/dev/null || true
    fi
  fi
  rm -f "$_diff_theirs"
  exit 0
fi

# Extract the lines theirs appended beyond the shared ancestor prefix.
theirs_tail=$(tail -n +"$((ancestor_lines + 1))" "$THEIRS")

if [[ -z "$theirs_tail" ]]; then
  # Theirs appended nothing; keep ours as-is.
  exit 0
fi

# INFRA-1199: validate that every '- name:' step in theirs_tail has a
# matching 'run:' or 'uses:' body.  An orphan name-only step causes GitHub
# Actions to reject the entire workflow file.  If validation fails, fall
# back to the standard 3-way merge (exit 1) rather than corrupt the file.
validate_step_bodies() {
  local tail="$1"
  local in_step=0
  local step_has_body=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]name: ]]; then
      # Entering a new step — check the previous one had a body.
      if [[ $in_step -eq 1 ]] && [[ $step_has_body -eq 0 ]]; then
        return 1
      fi
      in_step=1
      step_has_body=0
    elif [[ "$line" =~ ^[[:space:]]+(run|uses): ]]; then
      step_has_body=1
    fi
  done <<< "$tail"
  # Check the final step.
  if [[ $in_step -eq 1 ]] && [[ $step_has_body -eq 0 ]]; then
    return 1
  fi
  return 0
}

if ! validate_step_bodies "$theirs_tail"; then
  # INFRA-1199: theirs_tail has a '- name:' step without 'run:'/'uses:'.
  # Emit ambient event for auditability, then fall back to standard 3-way merge.
  _emit_ambient "ci_yml_merge_driver_abort" "orphan_step_no_body"
  give_up "orphan_step_no_body"
fi

# Safe to merge: append theirs' new steps to ours.
printf '%s\n%s\n' "$(cat "$OURS")" "$theirs_tail" > "$MERGE_FILE"

exit 0
