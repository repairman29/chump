#!/usr/bin/env bash
# test-ghost-gap-reaper.sh — integration test for INFRA-556 ghost-gap rollback.
# INFRA-1313: Also tests that closed_at (not updated_at) is used for lookback,
# and that meta-tracking gaps with [CI-RED], [ORPHAN], etc. titles are excluded.
#
# Fixtures:
#   gap_A: status=done, closed_pr=101 (PR 101 closed without merge) → must roll back to open
#   gap_B: status=done, closed_pr=102 (PR 102 merged)               → must stay done
#   gap_C: status=done, closed_pr=103 (PR 103 still open)           → must stay done (not yet decided)
#   gap_D: status=done, closed_pr="" (no PR recorded)               → must stay done (nothing to check)
#   gap_E: status=done, closed_pr=104, title="PR #104 stuck [CI-RED]" → must stay done (meta-tracking)
#   gap_F: status=done, closed_pr=105, title="ORPHAN-fix" → must stay done (meta-tracking)
#   gap_old: status=done, closed_pr=106, updated_at recent (commented on), closed_at old → must stay done (uses closed_at)
#
# Stubs out chump + gh with minimal shims; never touches real state.db or GitHub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/coord/ghost-gap-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: reaper not found or not executable: $REAPER"; exit 1; }

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ---------- stub: chump -------------------------------------------------------
# Accepts: gap list --status done --json   → returns fixture JSON
# Accepts: gap set <ID> --status open      → writes "$TMPDIR_TEST/rolled_back/<ID>"
STUB_CHUMP="$TMPDIR_TEST/bin/chump"
mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/rolled_back"

cat > "$STUB_CHUMP" <<'STUB'
#!/usr/bin/env bash
# Minimal chump shim for test-ghost-gap-reaper.sh
TMPDIR_TEST="$CHUMP_TEST_TMPDIR"
case "$*" in
  *"list --status done --json"*)
    cat <<'JSON'
[
  {"id":"gap_A","status":"done","closed_pr":"101","title":"gap A"},
  {"id":"gap_B","status":"done","closed_pr":"102","title":"gap B"},
  {"id":"gap_C","status":"done","closed_pr":"103","title":"gap C"},
  {"id":"gap_D","status":"done","closed_pr":"","title":"gap D"},
  {"id":"gap_E","status":"done","closed_pr":"104","title":"PR #104 stuck [CI-RED] — CI timeout"},
  {"id":"gap_F","status":"done","closed_pr":"105","title":"[ORPHAN]: gap for stuck PR"},
  {"id":"gap_old","status":"done","closed_pr":"106","title":"old gap"}
]
JSON
    ;;
  *"set gap_A --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_A"
    ;;
  *"set gap_B --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_B"
    ;;
  *"set gap_C --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_C"
    ;;
  *"set gap_E --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_E"
    ;;
  *"set gap_F --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_F"
    ;;
  *"set gap_old --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_old"
    ;;
  *)
    ;;
esac
exit 0
STUB
chmod +x "$STUB_CHUMP"

# ---------- stub: gh ----------------------------------------------------------
# Accepts: pr view <N> --json state,mergedAt
STUB_GH="$TMPDIR_TEST/bin/gh"
cat > "$STUB_GH" <<'STUB'
#!/usr/bin/env bash
# gh shim: pr view <N> --json state,mergedAt
# Also handles the REST pull API response format used by ghost-gap-reaper
case "$*" in
  *"repos"*"pulls?state=closed"*)
    # REST API response for closed PRs (103 is still open, so not in this list)
    cat <<'JSON'
[
  {"number":101,"state":"closed","merged_at":null,"closed_at":"2026-05-10T10:00:00Z","updated_at":"2026-05-10T10:00:00Z"},
  {"number":102,"state":"closed","merged_at":"2026-05-06T10:00:00Z","closed_at":"2026-05-06T10:00:00Z","updated_at":"2026-05-06T10:00:00Z"},
  {"number":104,"state":"closed","merged_at":null,"closed_at":"2026-05-10T10:00:00Z","updated_at":"2026-05-10T10:00:00Z"},
  {"number":105,"state":"closed","merged_at":null,"closed_at":"2026-05-10T10:00:00Z","updated_at":"2026-05-10T10:00:00Z"},
  {"number":106,"state":"closed","merged_at":null,"closed_at":"2026-05-08T10:00:00Z","updated_at":"2026-05-14T23:59:00Z"}
]
JSON
    ;;
  *)
    echo '{"state":"MERGED","mergedAt":"2026-05-06T00:00:00Z"}'
    ;;
esac
exit 0
STUB
chmod +x "$STUB_GH"

# ---------- stub: ambient-emit.sh ---------------------------------------------
mkdir -p "$TMPDIR_TEST/scripts/dev"
cat > "$TMPDIR_TEST/scripts/dev/ambient-emit.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMPDIR_TEST/scripts/dev/ambient-emit.sh"

# ---------- run reaper with stubs in PATH ------------------------------------
OUT=$(PATH="$TMPDIR_TEST/bin:$PATH" \
    CHUMP_REPO="$TMPDIR_TEST" \
    CHUMP_BINARY_STALENESS_CHECK=0 \
    HOME="$TMPDIR_TEST" \
    CHUMP_TEST_TMPDIR="$TMPDIR_TEST" \
    "$REAPER" 2>&1 || true)

echo "$OUT"

# ---------- assertions -------------------------------------------------------
FAIL=0

if [[ -f "$TMPDIR_TEST/rolled_back/gap_A" ]]; then
    echo "PASS: gap_A (PR closed without merge) was rolled back to open"
else
    echo "FAIL: gap_A should have been rolled back but was not"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_B" ]]; then
    echo "PASS: gap_B (PR merged) was NOT rolled back"
else
    echo "FAIL: gap_B should NOT have been rolled back (PR merged)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_C" ]]; then
    echo "PASS: gap_C (PR still open) was NOT rolled back"
else
    echo "FAIL: gap_C should NOT have been rolled back (PR still open)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_D" ]]; then
    echo "PASS: gap_D (no closed_pr) was NOT rolled back"
else
    echo "FAIL: gap_D should NOT have been rolled back (no PR)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_E" ]]; then
    echo "PASS: gap_E (meta-tracking [CI-RED]) was NOT rolled back"
else
    echo "FAIL: gap_E should NOT have been rolled back (meta-tracking gap with [CI-RED])"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_F" ]]; then
    echo "PASS: gap_F (meta-tracking ORPHAN) was NOT rolled back"
else
    echo "FAIL: gap_F should NOT have been rolled back (meta-tracking gap with ORPHAN)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_old" ]]; then
    echo "PASS: gap_old (closed_at outside window) was NOT rolled back"
else
    echo "FAIL: gap_old should NOT have been rolled back (closed_at outside 7-day window)"
    FAIL=1
fi

# Output must mention the rollback
echo "$OUT" | grep -q "gap_A" \
    || { echo "FAIL: output missing gap_A rollback message"; FAIL=1; }

echo "$OUT" | grep -q "rolled back 1 ghost gap(s)" \
    || { echo "FAIL: summary line 'rolled back 1 ghost gap(s)' not found in output"; FAIL=1; }

exit $FAIL
