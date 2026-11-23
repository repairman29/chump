#!/usr/bin/env bash
# scripts/ci/test-required-checks-non-empty.sh — INFRA-2201
#
# Asserts the resilience invariant from INFRA-2201:
#   At least ONE of (branch-protection, ruleset) on main must have a
#   non-empty required_status_checks list. Both empty = silently
#   unprotected main = critical breach.
#
# Why this exists: 2026-05-29T22:30Z the shepherd ran an admin-merge
# cycle to clear a stuck PR queue, dropped required_status_checks on
# both branch-protection AND ruleset 15133729, and only restored them
# after a sibling agent's HANDOFF flagged it. No ambient emit, no
# fleet-doctor alert, no watchdog ping fired during the open window.
# This script is the cheap CI gate that catches the empty state at
# every fast-checks shard run.
#
# Wire-up:
#   - Called from scripts/ci/test-*.sh aggregator (fast-checks shard).
#   - Called from scripts/coord/fleet-doctor-strict.sh check function
#     `check_required_status_checks` for live monitoring.
#
# Bypass:
#   CHUMP_REQUIRED_CHECKS_NON_EMPTY_SKIP=1
#       Skip the check entirely. Use only in PRs that intentionally
#       relax the protection (e.g. INFRA-2201 itself, before the
#       check is wired live).
#
# Exit codes:
#   0  invariant holds (at least one source has required checks)
#   1  invariant FAILS (both sources empty — emergency)
#   2  could not evaluate (gh not available, offline, etc.)

set -euo pipefail

if [[ "${CHUMP_REQUIRED_CHECKS_NON_EMPTY_SKIP:-0}" == "1" ]]; then
    echo "[required-checks] SKIP: CHUMP_REQUIRED_CHECKS_NON_EMPTY_SKIP=1"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[required-checks] SKIP: gh CLI not in PATH"
    exit 2
fi

REPO="${CHUMP_REPO_NWO:-}"
if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
fi
if [[ -z "$REPO" ]]; then
    echo "[required-checks] SKIP: could not resolve repo NWO (no remote OR offline)"
    exit 2
fi

# Sub-check A: classic branch-protection
BP_COUNT="$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    c=d.get("required_status_checks",{}).get("checks",[])
    print(len(c))
except Exception:
    print(0)' || echo 0)"

# Sub-check B: ruleset-side required_status_checks (any active ruleset
# scoped to ~DEFAULT_BRANCH counts)
RS_TOTAL=0
while IFS= read -r RID; do
    [[ -z "$RID" ]] && continue
    N="$(gh api "repos/$REPO/rulesets/$RID" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    r=json.load(sys.stdin)
    for rule in r.get("rules",[]):
        if rule.get("type")=="required_status_checks":
            print(len(rule.get("parameters",{}).get("required_status_checks",[])))
            break
    else:
        print(0)
except Exception:
    print(0)' || echo 0)"
    RS_TOTAL=$(( RS_TOTAL + N ))
done < <(gh api "repos/$REPO/rulesets" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    rs=json.load(sys.stdin)
    for r in rs:
        if r.get("enforcement")=="active":
            print(r.get("id",""))
except Exception:
    pass' || true)

TOTAL=$(( BP_COUNT + RS_TOTAL ))
echo "[required-checks] branch-protection=$BP_COUNT  ruleset_total=$RS_TOTAL  combined=$TOTAL"

if [[ "$TOTAL" -eq 0 ]]; then
    echo "[required-checks] FAIL: both branch-protection AND ruleset required_status_checks are EMPTY"
    echo "                  main is silently UNPROTECTED — restore via scripts/ops/admin-merge-cycle.sh"
    echo "                  or by PUTing repo/rulesets/<id> with the canonical required_status_checks rule"
    exit 1
fi

echo "[required-checks] PASS: invariant holds (combined=$TOTAL ≥ 1)"
exit 0
