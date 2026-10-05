#!/usr/bin/env bash
# test-in-progress-branches-stale.sh — RESILIENT-1509
#
# worker.sh's RESILIENT-332 anti-spin Layer B excluded ANY gap with a pushed
# chump/<gapid>-fleet-* branch on origin from the picker. 1,437 dead
# wip/*-style branches accumulated (crashed workers, abandoned claims) and
# ~91 open gaps whose ONLY blocker was a stale leftover branch sat
# permanently unpickable even though nothing was actually in flight.
#
# scripts/dispatch/_in_progress_branches.py now requires an open PR OR
# recent commit activity before a branch counts as "in progress". This
# exercises that pure filter directly (no git/network needed).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILTER="$REPO_ROOT/scripts/dispatch/_in_progress_branches.py"

[[ -f "$FILTER" ]] || { echo "FAIL: $FILTER missing"; exit 1; }

NOW=2000000000
STALE_HOURS=6

run() {
    python3 "$FILTER" "$NOW" "$STALE_HOURS"
}

# 1. A branch with NO open PR and NO recent activity (commit 10h ago,
#    stale_hours=6) must NOT block its gap — this is the exact RESILIENT-1509
#    failure mode (stale leftover branch, 91 gaps wrongly excluded).
STALE_TS=$((NOW - 10*3600))
out="$(printf 'RESILIENT-1509\t%s\t0\n' "$STALE_TS" | run)"
[[ -z "$out" ]] && pass "stale branch (no PR, 10h old) does NOT block its gap" \
    || fail "stale branch wrongly reported in-progress: '$out'"

# 2. A branch with NO open PR but RECENT activity (commit 1h ago) still
#    blocks — a worker may be mid-push right now.
RECENT_TS=$((NOW - 1*3600))
out="$(printf 'RESILIENT-1510\t%s\t0\n' "$RECENT_TS" | run)"
[[ "$out" == "RESILIENT-1510" ]] && pass "recent branch (no PR, 1h old) still blocks its gap" \
    || fail "recent branch should block, got: '$out'"

# 3. A branch with an OPEN PR blocks regardless of age (10h old commit,
#    but PR is open) — the real signal of in-progress work.
out="$(printf 'RESILIENT-1511\t%s\t1\n' "$STALE_TS" | run)"
[[ "$out" == "RESILIENT-1511" ]] && pass "branch with open PR blocks even when old" \
    || fail "open-PR branch should block, got: '$out'"

# 4. Unknown commit timestamp (0 / missing) with no open PR: fails safe
#    towards PICKABLE (a leftover branch from an old convention is far
#    more likely dead than brand new).
out="$(printf 'RESILIENT-1512\t0\t0\n' | run)"
[[ -z "$out" ]] && pass "unknown-age branch with no PR does not block (fails open)" \
    || fail "unknown-age branch wrongly blocked: '$out'"

# 5. Mixed batch: only the genuinely in-progress ones survive, deduped.
batch="$(cat <<EOF
AAA-1	$STALE_TS	0
BBB-2	$RECENT_TS	0
BBB-2	$RECENT_TS	0
CCC-3	$STALE_TS	1
EOF
)"
out="$(printf '%s\n' "$batch" | run | sort | tr '\n' ' ')"
[[ "$out" == "BBB-2 CCC-3 " ]] && pass "mixed batch: only recent+open-PR gaps survive, deduped (got: $out)" \
    || fail "mixed batch wrong result: '$out' (want 'BBB-2 CCC-3 ')"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
