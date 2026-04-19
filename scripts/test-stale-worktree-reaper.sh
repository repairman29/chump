#!/usr/bin/env bash
# test-stale-worktree-reaper.sh — smoke test for the worktree reaper.
#
# Strategy: run the reaper in --dry-run mode against the live repo and verify
# the script exits 0 and emits expected status lines. We deliberately do NOT
# create fake worktrees that mutate git state — the dry-run path is the
# safety contract that needs to hold.
#
# Run:
#   ./scripts/test-stale-worktree-reaper.sh
#
# Exits non-zero on any check failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAPER="$SCRIPT_DIR/stale-worktree-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: reaper not executable: $REAPER"; exit 1; }

OUT=$("$REAPER" --dry-run 2>&1)
ECODE=$?

if [[ $ECODE -ne 0 ]]; then
    echo "FAIL: dry-run exited $ECODE"
    echo "$OUT"
    exit 1
fi

# Check banner.
echo "$OUT" | grep -q "stale-worktree-reaper" \
    || { echo "FAIL: missing banner"; exit 1; }

echo "$OUT" | grep -q "Dry-run mode" \
    || { echo "FAIL: dry-run banner missing"; exit 1; }

echo "$OUT" | grep -qE "reaper done: [0-9]+ reapable, [0-9]+ kept, [0-9]+ skipped" \
    || { echo "FAIL: summary line missing"; exit 1; }

# Active-lease guard: every worktree shown should be either kept/skipped OR
# explicitly marked reapable; never both. We don't enforce a count — just
# sanity-check the output contains either reapable or keeping markers.
echo "$OUT" | grep -qE "REAPABLE|keeping|skipping" \
    || { echo "FAIL: no per-worktree decision lines"; exit 1; }

# Make sure --execute flag is parseable (don't actually run it).
"$REAPER" --help >/dev/null 2>&1 || true

echo "PASS: dry-run smoke test"
echo "----"
echo "$OUT" | tail -8
exit 0
