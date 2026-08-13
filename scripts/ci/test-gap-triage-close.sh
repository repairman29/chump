#!/usr/bin/env bash
# test-gap-triage-close.sh — RESILIENT-119
#
# Verifies `chump gap close <ID> --reason <R>` is a first-class triage-close
# path: it flips status WITHOUT requiring the clean/current-worktree guard
# (INFRA-2423) or the proof-of-merge guard (INFRA-1392) that `chump gap ship`
# enforces, since those guards protect PR-ships and a triage-close never has
# a PR. It replaces the old band-aid:
#   git reset --hard origin/main && CHUMP_BINARY_STALENESS_CHECK=0 \
#     chump gap edit --status superseded
#
# AC:
#   1. `chump gap close <ID> --reason <R>` flips status for R in
#      {superseded, wontfix, obsolete, duplicate}.
#   2. Succeeds even with uncommitted local changes present (no
#      clean/current-worktree gate) and with no PR/merge commit naming the
#      gap anywhere on main (no proof-of-merge gate).
#   3. Rejects an invalid --reason.
#   4. Emits kind=gap_triage_closed with the reason to ambient.jsonl.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

CHUMP_BIN="${CHUMP_BIN:-chump}"
command -v "$CHUMP_BIN" >/dev/null 2>&1 || fail "Cannot find chump binary"

cd "$REPO_ROOT" || fail "Cannot cd to $REPO_ROOT"

# Pin CHUMP_REPO so state.db + ambient.jsonl resolve to this checkout even
# when the test happens to run from a linked worktree.
export CHUMP_REPO="$REPO_ROOT"

# ── Test 1..4: one gap per valid reason ─────────────────────────────────────
for REASON in superseded wontfix obsolete duplicate; do
  TEST_GAP=$($CHUMP_BIN gap reserve --domain RESILIENT --title "RESILIENT: triage-close smoke ($REASON)" --priority P3 --force 2>&1 | grep '^RESILIENT-' | tail -1)
  [ -n "$TEST_GAP" ] || fail "Cannot reserve test gap for reason=$REASON"

  status_before=$($CHUMP_BIN gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
  [ "$status_before" = "open" ] || fail "Gap not open before close ($REASON): $status_before"

  # No proof-of-merge commit exists for this gap ID, and we intentionally do
  # NOT clean/rebase the worktree — this is the point of the test.
  $CHUMP_BIN gap close "$TEST_GAP" --reason "$REASON" \
    || fail "gap close --reason $REASON failed"

  status_after=$($CHUMP_BIN gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
  [ "$status_after" = "$REASON" ] || fail "Status not $REASON after close: got $status_after"
  pass "gap close --reason $REASON flips status without ship-path guards ($TEST_GAP)"

  if [ -f "$REPO_ROOT/.chump-locks/ambient.jsonl" ]; then
    tail -50 "$REPO_ROOT/.chump-locks/ambient.jsonl" | grep -q "\"kind\":\"gap_triage_closed\".*\"gap_id\":\"$TEST_GAP\".*\"reason\":\"$REASON\"" \
      || fail "gap_triage_closed ambient event missing/malformed for $TEST_GAP"
    pass "gap_triage_closed ambient event emitted for $TEST_GAP"
  fi
done

# ── Test 5: invalid --reason is rejected ────────────────────────────────────
TEST_GAP=$($CHUMP_BIN gap reserve --domain RESILIENT --title "RESILIENT: triage-close invalid-reason smoke" --priority P3 --force 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$TEST_GAP" ] || fail "Cannot reserve test gap for invalid-reason case"
if $CHUMP_BIN gap close "$TEST_GAP" --reason bogus 2>/dev/null; then
  fail "gap close accepted an invalid --reason"
fi
status_after=$($CHUMP_BIN gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$status_after" = "open" ] || fail "Gap status changed despite invalid --reason: $status_after"
pass "gap close rejects invalid --reason and leaves status unchanged"

pass "All RESILIENT-119 gap-close tests passed"
