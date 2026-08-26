#!/usr/bin/env bash
# test-infra-3803-retire-stale-conflicting.sh — INFRA-3803
#
# Validates the stale-pr-reaper.sh "retire stale+conflicting PRs" pass
# (INFRA-3604 slice):
#   AC1: a demoted gap's stale (>7d) + conflicting PR gets closed within
#        the reaper's normal cadence (no demotion-specific gate — the check
#        fires purely on PR staleness + conflict state, see AC3).
#   AC2: the reaper adds the 'retired' label to such closed PRs.
#   AC3: the reaper closes stale+conflicting PRs unconditionally (not gated
#        on any gap-demotion signal).
#
# Static checks + a synthetic selection-logic test (via CHUMP_RETIRE_PR_JSON,
# dry-run — no live GitHub calls).

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-pr-reaper.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-3803 retire-stale-conflicting test ==="
echo

# ── 1. Static checks ─────────────────────────────────────────────────────────
echo "[static checks]"

if [[ -x "$REAPER" ]]; then
    ok "stale-pr-reaper.sh exists and is executable"
else
    fail "stale-pr-reaper.sh missing or not executable: $REAPER"
fi

if bash -n "$REAPER"; then
    ok "stale-pr-reaper.sh parses"
else
    fail "stale-pr-reaper.sh has syntax errors"
fi

for needle in \
    'CHUMP_RETIRE_LABEL' \
    'STALE_PR_DAYS' \
    'CHUMP_RETIRE_STALE_CONFLICTING' \
    'pr_retired' ; do
    if grep -qE "$needle" "$REAPER"; then
        ok "reaper contains '$needle'"
    else
        fail "reaper missing '$needle'"
    fi
done

if grep -q 'RETIRE_LABEL:-retired' "$REAPER"; then
    ok "default retire label is 'retired' (AC #2)"
else
    fail "default retire label is not 'retired' — AC #2 requires the 'retired' label"
fi

if grep -qE '"\$R_MSTATE" != "DIRTY" && "\$R_MERGEABLE" != "CONFLICTING"' "$REAPER"; then
    ok "reaper checks both DIRTY and CONFLICTING conflict signals"
else
    fail "reaper does not check both DIRTY and CONFLICTING conflict signals"
fi

# The AC #3 requirement: the close is NOT gated on any demotion-detection
# signal — it must fire purely off staleness + conflict state.
if grep -q 'unconditional on gap priority' "$REAPER" || grep -q 'AC #3' "$REAPER"; then
    ok "reaper documents the unconditional (non-demotion-gated) policy (AC #3)"
else
    fail "reaper does not document the AC #3 unconditional policy"
fi

# ── 2. EVENT_REGISTRY has pr_retired with required fields ───────────────────
echo
echo "[event registry]"

if grep -q 'kind: pr_retired' "$REGISTRY"; then
    ok "pr_retired registered in EVENT_REGISTRY.yaml"
else
    fail "pr_retired missing from EVENT_REGISTRY.yaml"
fi

for field in ts kind pr label stale_days gap_ids; do
    if grep -A6 'kind: pr_retired' "$REGISTRY" | grep -q "$field"; then
        ok "EVENT_REGISTRY pr_retired fields_required includes '$field'"
    else
        fail "EVENT_REGISTRY pr_retired fields_required missing '$field'"
    fi
done

# ── 3. Synthetic selection-logic test (dry-run, fixture PR list) ────────────
echo
echo "[synthetic selection logic — dry-run, no live GitHub calls]"

if ! command -v gh >/dev/null 2>&1; then
    echo "  (gh CLI not available — skipping end-to-end dry-run exercise)"
else
    TMPDIR_BASE="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_BASE"' EXIT

    STALE_TS=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    FRESH_TS=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

    FIXTURE="$TMPDIR_BASE/prs.json"
    cat >"$FIXTURE" <<EOF
[
  {"number": 9001, "title": "feat(INFRA-9001): demoted gap work", "headRefName": "b1",
   "mergeStateStatus": "DIRTY", "mergeable": "CONFLICTING", "updatedAt": "$STALE_TS", "labels": []},
  {"number": 9002, "title": "feat(INFRA-9002): fresh conflict", "headRefName": "b2",
   "mergeStateStatus": "DIRTY", "mergeable": "CONFLICTING", "updatedAt": "$FRESH_TS", "labels": []},
  {"number": 9003, "title": "feat(INFRA-9003): stale but clean", "headRefName": "b3",
   "mergeStateStatus": "CLEAN", "mergeable": "MERGEABLE", "updatedAt": "$STALE_TS", "labels": []},
  {"number": 9004, "title": "feat(INFRA-9004): stale conflicting but exempt", "headRefName": "b4",
   "mergeStateStatus": "DIRTY", "mergeable": "CONFLICTING", "updatedAt": "$STALE_TS", "labels": [{"name": "do-not-respawn"}]}
]
EOF

    OUT=$(cd "$REPO_ROOT" && CHUMP_RETIRE_PR_JSON="$FIXTURE" CHUMP_PR_AUTO_RESPAWN=0 \
        REAPER_LOCK_DIR="$TMPDIR_BASE" \
        "$REAPER" --dry-run 2>&1 || true)

    if echo "$OUT" | grep -q "would label 'retired' + close PR #9001"; then
        ok "PR #9001 (stale + CONFLICTING) selected for retirement"
    else
        fail "PR #9001 (stale + CONFLICTING) NOT selected — output:\n$OUT"
    fi

    if echo "$OUT" | grep -q "would label 'retired' + close PR #9002"; then
        fail "PR #9002 (fresh conflict, < 7d) incorrectly selected for retirement"
    else
        ok "PR #9002 (fresh conflict) correctly left alone"
    fi

    if echo "$OUT" | grep -q "would label 'retired' + close PR #9003"; then
        fail "PR #9003 (stale but clean/mergeable) incorrectly selected for retirement"
    else
        ok "PR #9003 (stale but not conflicting) correctly left alone"
    fi

    if echo "$OUT" | grep -q "would label 'retired' + close PR #9004"; then
        fail "PR #9004 (do-not-respawn exempt) incorrectly selected for retirement"
    else
        ok "PR #9004 (do-not-respawn label) correctly exempted"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
