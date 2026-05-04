#!/usr/bin/env bash
# merge-driver-gap-yaml-add-line.sh — INFRA-310
#
# Custom merge driver for docs/gaps/*.yaml conflicts.
# Per-file gap YAMLs typically don't conflict (separate files per gap).
# Exception: bot-merge auto-close + manual close racing on same gap.
# Resolution: take 'ours' (the current/newer version).
#
# For any conflict in a gap YAML, this driver simply uses the "ours" version
# since we assume "ours" is the more recent state when multiple agents race.

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

# For gap YAMLs, conflicts typically only occur when both branches are closing
# the same gap (auto-close + manual close racing). In that case, take 'ours'
# (the current state on the branch being merged/rebased).
# This is safe because the canonical state is in .chump/state.db anyway.

# Simply keep ours as-is (which is already in MERGE_FILE by virtue of the
# file being staged there by git before the driver is called).
exit 0
