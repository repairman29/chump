#!/usr/bin/env bash
# merge-driver-state-sql-regen.sh — INFRA-310
#
# Custom merge driver for .chump/state.sql conflicts.
# When both branches modify the SQL dump (typically from parallel `chump gap reserve`
# calls), this driver regenerates the dump from the canonical .chump/state.db
# instead of attempting a textual merge.
#
# Usage (called by git): <driver> %O %A %B %L
#   %O = original (ancestor) file path
#   %A = ours (current branch) file path
#   %B = theirs (branch being merged) file path
#   %L = conflict marker length (number)
#
# The driver modifies $2 (the "ours" file) in place with the merged result.
#
# Exit codes:
#   0 = merge succeeded, conflict resolved, file modified in-place
#   1 = merge failed, fallback to manual conflict markers
#   2+ = error (invalid inputs, missing db)

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
ANCESTOR="$1"
OURS="$2"
THEIRS="$3"
# CONFLICT_MARKER_LEN="$4"  # not used
MERGE_FILE="$OURS"  # Write result to the "ours" file

# Sanity checks
if [[ ! -f "$ANCESTOR" ]] || [[ ! -f "$OURS" ]] || [[ ! -f "$THEIRS" ]]; then
  echo "merge-driver-state-sql-regen: missing input file(s)" >&2
  exit 1
fi

# The canonical source is .chump/state.db, not the textual dump.
# Verify it exists in the repo root (reached via git rev-parse).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "merge-driver-state-sql-regen: not in a git repo" >&2
  exit 1
}

STATE_DB="$REPO_ROOT/.chump/state.db"
if [[ ! -f "$STATE_DB" ]]; then
  echo "merge-driver-state-sql-regen: canonical state.db missing at $STATE_DB" >&2
  echo "  → falling back to manual conflict resolution" >&2
  exit 1
fi

# Regenerate the SQL dump from the canonical database.
# The chump binary is expected to be in $PATH; override with CHUMP_BIN env.
if ! command -v "$CHUMP_BIN" >/dev/null 2>&1; then
  echo "merge-driver-state-sql-regen: $CHUMP_BIN not found" >&2
  echo "  → falling back to manual conflict resolution" >&2
  exit 1
fi

if ! "$CHUMP_BIN" gap dump --out "$MERGE_FILE" 2>/dev/null; then
  echo "merge-driver-state-sql-regen: chump gap dump failed" >&2
  echo "  → falling back to manual conflict resolution" >&2
  exit 1
fi

# Success: MERGE_FILE now contains the canonical dump.
exit 0
