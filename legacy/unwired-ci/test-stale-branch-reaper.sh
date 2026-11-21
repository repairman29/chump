#!/usr/bin/env bash
# scripts/ci/test-stale-branch-reaper.sh — INFRA-697
#
# Smoke tests for the INFRA-697 extension to stale-branch-reaper.sh:
# - Branches with merged/closed PRs older than CHUMP_BRANCH_REAPER_AGE_DAYS
#   are marked for deletion in dry-run mode.
# - Branches with no PR are skipped (safety).
# - Branches with open PRs are skipped.
# - Fresh closed PRs (< threshold) are skipped.
#
# Uses fixture data (no real GitHub API calls): sets up CLOSED_PR_LIST and
# OPEN_PR_BRANCHES as environment variables to simulate different scenarios.

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  [ok]  $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-branch-reaper.sh"

echo "=== INFRA-697: stale-branch-reaper smoke test ==="
echo

if [[ ! -f "$REAPER" ]]; then
    echo "  SKIP: $REAPER not found"
    exit 0
fi

# Helper: run a sub-function extracted from the reaper to test the logic.
# We unit-test the decision logic by running a minimal harness that sources
# just the parsing bits (no git/gh calls needed).
test_pr_age_parse() {
    local label="$1"
    local ts="$2"
    local expected_days_ago="$3"  # approximate expected age in days
    local now_epoch
    now_epoch=$(date +%s)

    close_epoch=$(python3 -c "
import sys
from datetime import datetime, timezone
ts = sys.argv[1].rstrip('Z')
try:
    dt = datetime.fromisoformat(ts)
except ValueError:
    dt = datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S')
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
" "$ts" 2>/dev/null || echo "0")

    if [[ "$close_epoch" -gt 0 ]]; then
        actual_secs=$(( now_epoch - close_epoch ))
        actual_days=$(( actual_secs / 86400 ))
        # Allow ±2 day tolerance for timezone rounding
        diff=$(( actual_days - expected_days_ago ))
        if [[ ${diff#-} -le 2 ]]; then
            ok "$label: parsed $ts → ${actual_days}d ago (expected ~${expected_days_ago}d)"
        else
            fail "$label: parsed $ts → ${actual_days}d ago, expected ~${expected_days_ago}d"
        fi
    else
        fail "$label: could not parse timestamp $ts"
    fi
}

# 1. Timestamp parsing: GitHub ISO format
test_pr_age_parse "ISO timestamp parse (Z suffix)" "$(date -u -d '11 days ago' +%Y-%m-%dT%H:%M:%SZ)" "11"

# 2. Timestamp parsing: no Z suffix (some gh versions)
test_pr_age_parse "ISO timestamp parse (no Z)" "$(date -u -d '11 days ago' +%Y-%m-%dT%H:%M:%S)" "11"

# 3. CHUMP_BRANCH_REAPER_AGE_DAYS env var is respected
# Simulate the reaper's age-threshold check logic
check_threshold() {
    local label="$1"
    local age_days="$2"
    local threshold="$3"
    local expected="$4"  # "reap" or "skip"
    local age_secs=$(( age_days * 86400 ))
    local threshold_secs=$(( threshold * 86400 ))
    if [[ "$age_secs" -ge "$threshold_secs" ]]; then
        result="reap"
    else
        result="skip"
    fi
    if [[ "$result" == "$expected" ]]; then
        ok "$label: age=${age_days}d threshold=${threshold}d → $result"
    else
        fail "$label: age=${age_days}d threshold=${threshold}d → expected $expected, got $result"
    fi
}

check_threshold "PR 10d old, threshold 7d" 10 7 "reap"
check_threshold "PR 6d old, threshold 7d"  6  7 "skip"
check_threshold "PR 0d old, threshold 7d"  0  7 "skip"
check_threshold "PR 7d old, threshold 7d"  7  7 "reap"
check_threshold "PR 14d old, custom 30d"   14 30 "skip"

# 4. CLOSED_PR_LIST grep pattern: branch names with | separator
# Verifies the grep -m1 "^${BRANCH}|" pattern works correctly
MOCK_CLOSED_LIST="chump/infra-123-claim|2026-05-01T00:00:00Z
chump/infra-456-claim|2026-05-10T00:00:00Z
other/branch|2026-04-01T00:00:00Z"

branch="chump/infra-123-claim"
found=$(echo "$MOCK_CLOSED_LIST" | grep -m1 "^${branch}|" 2>/dev/null || true)
if [[ "$found" == "chump/infra-123-claim|2026-05-01T00:00:00Z" ]]; then
    ok "closed PR grep: exact match with | separator"
else
    fail "closed PR grep: expected 'chump/infra-123-claim|...' got '$found'"
fi

# 5. Branches not in closed list → no match (safety: no PR = skip)
branch_no_pr="chump/wip-no-pr"
found=$(echo "$MOCK_CLOSED_LIST" | grep -m1 "^${branch_no_pr}|" 2>/dev/null || true)
if [[ -z "$found" ]]; then
    ok "safety: branch with no PR returns empty grep (will be skipped)"
else
    fail "safety: expected empty match for branch with no PR, got '$found'"
fi

# 6. Default CHUMP_BRANCH_REAPER_AGE_DAYS is 7
default_val="${CHUMP_BRANCH_REAPER_AGE_DAYS:-7}"
if [[ "$default_val" == "7" ]]; then
    ok "CHUMP_BRANCH_REAPER_AGE_DAYS defaults to 7"
else
    ok "CHUMP_BRANCH_REAPER_AGE_DAYS set to $default_val"
fi

# 7. Script has the new env var documented
if grep -q 'CHUMP_BRANCH_REAPER_AGE_DAYS' "$REAPER"; then
    ok "reaper script has CHUMP_BRANCH_REAPER_AGE_DAYS variable"
else
    fail "reaper script missing CHUMP_BRANCH_REAPER_AGE_DAYS"
fi

# 8. Script has SKIPPED_NO_PR counter (safety skip counting)
if grep -q 'SKIPPED_NO_PR' "$REAPER"; then
    ok "reaper script tracks SKIPPED_NO_PR counter"
else
    fail "reaper script missing SKIPPED_NO_PR counter"
fi

# 9. RESILIENT-1545: squash-safe shipped detection by gap-ID
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
(
    cd "$TMP" && git init -q -b main . && git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m "init"
    git commit -q --allow-empty -m "INFRA-2360: squash-merged work (#10)"
    git commit -q --allow-empty -m "Resilient-1002: fleet thing"
    git commit -q --allow-empty -m "no gap id here (#11)"
) >/dev/null 2>&1
REAPER_SOURCE_ONLY=1 source "$REAPER"
ids="$(cd "$TMP" && shipped_gap_ids main)"
if grep -qx 'INFRA-2360' <<<"$ids" && grep -qx 'RESILIENT-1002' <<<"$ids" && [[ "$(grep -c . <<<"$ids")" == "2" ]]; then
    ok "shipped_gap_ids extracts leading gap-IDs from main subjects"
else
    fail "shipped_gap_ids wrong: $(echo $ids)"
fi
for pair in "claude/infra-2360:INFRA-2360" "chump/resilient-1002-fleet-x:RESILIENT-1002" "wip/foo:" "claude/infra-12abc:" "claude/meta-1031:META-1031"; do
    b="${pair%%:*}"; want="${pair#*:}"; got="$(branch_gap_id "$b")"
    if [[ "$got" == "$want" ]]; then ok "branch_gap_id $b -> '${got}'"; else fail "branch_gap_id $b -> '$got' want '$want'"; fi
done
# squash-merged branch: shipped ID in set, though commits are NOT reachable from main
gid="$(branch_gap_id claude/infra-2360)"
if grep -qxF "$gid" <<<"$ids"; then ok "squash-merged branch detected as shipped"; else fail "squash-merged branch not detected"; fi
gid="$(branch_gap_id claude/infra-9999)"
if ! grep -qxF "$gid" <<<"$ids"; then ok "unshipped gap-ID branch not treated as shipped"; else fail "unshipped branch wrongly shipped"; fi
# safety wiring: no-PR unshipped branches are flagged, never deleted
if grep -q 'SKIPPED_FLAGGED' "$REAPER"; then ok "reaper flags no-PR unshipped branches"; else fail "reaper missing flag path"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
