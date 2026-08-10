#!/usr/bin/env bash
# pr-triage-reporter.sh — the unmerged-work REPORTER (EFFECTIVE-435 / COTG).
#
# WHY THIS EXISTS (operator, 2026-08-10): "Some work sitting there not merged is
# probably our most important thing — otherwise why the hell did we do it? If it's
# crap, delete it. If it needs fixing to get on main, make that a priority."
#
# Everything else in the fleet tries to PUSH work through (arm, rebase, rerun,
# reap-superseded). NOTHING understands work that is STUCK and decides its fate.
# This is that organ: a reporter + router, not a fixer. For every open fleet PR
# that isn't merging, it: (1) understands WHY, (2) REPORTS the reason loudly, and
# (3) ROUTES it — crap→close, valuable-but-broken→file a P1 fix gap the fleet picks
# back up, flaky/behind→name the handler that owns it. So nothing sits silently.
#
# It NEVER deletes valuable work — it only closes work that is already-superseded
# (its gap is done on main) or has no diff. Broken-but-valuable work is escalated
# to a P1 fix gap, not thrown away.
#
# Usage: pr-triage-reporter.sh [--dry-run] [--apply]
#   default = report only.  --apply = also close-superseded + file fix gaps.
set -uo pipefail

DRY=1; APPLY=0
for a in "$@"; do case "$a" in --dry-run) DRY=1;; --apply) APPLY=1; DRY=0;; esac; done

ME="$(gh api user --jq .login 2>/dev/null || echo repairman29)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo /root/Projects/chump)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
COOLDOWN="$REPO_ROOT/.chump-locks/triage-fix-filed"; mkdir -p "$COOLDOWN" 2>/dev/null || true
ts(){ date -u +%FT%TZ; }
emit(){ printf '{"ts":"%s","kind":"%s","pr":%s,"verdict":"%s","reason":"%s"}\n' "$(ts)" "$1" "$2" "$3" "$4" >> "$AMBIENT" 2>/dev/null || true; }

echo "=== unmerged-work triage $(ts) (author=$ME, $([ $APPLY -eq 1 ] && echo APPLY || echo report-only)) ==="
n_super=0; n_broken=0; n_flaky=0; n_behind=0; n_pending=0; n_ok=0

for pr in $(gh pr list --author "$ME" --state open --limit 40 --json number -q '.[].number' 2>/dev/null); do
    j="$(gh pr view "$pr" --json number,title,mergeStateStatus,headRefName,createdAt,statusCheckRollup 2>/dev/null)" || continue
    title="$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin)["title"][:55])' 2>/dev/null)"
    ms="$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin)["mergeStateStatus"])' 2>/dev/null)"
    branch="$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin)["headRefName"])' 2>/dev/null)"
    age_h="$(printf '%s' "$j" | python3 -c 'import sys,json,datetime as d;c=json.load(sys.stdin)["createdAt"];print(int((d.datetime.now(d.timezone.utc)-d.datetime.fromisoformat(c.replace("Z","+00:00"))).total_seconds()//3600))' 2>/dev/null)"
    fails="$(printf '%s' "$j" | python3 -c 'import sys,json;r=json.load(sys.stdin).get("statusCheckRollup",[]);print(",".join(sorted({c["name"] for c in r if c.get("conclusion")=="FAILURE"})))' 2>/dev/null)"
    gap="$(printf '%s' "$branch$title" | grep -oiE '[A-Z]+-[0-9]+' | head -1 | tr a-z A-Z)"

    # merging fine → not our problem
    if [[ "$ms" == "CLEAN" || "$ms" == "HAS_HOOKS" || "$ms" == "UNSTABLE" || "$ms" == "UNKNOWN" ]] && [[ -z "$fails" ]]; then
        n_ok=$((n_ok+1)); continue
    fi

    # gap already done on main → SUPERSEDED → safe to delete
    gapdone=""
    [[ -n "$gap" ]] && gapdone="$(cd "$REPO_ROOT" && chump gap show "$gap" 2>/dev/null | grep -iE '^status:' | grep -io 'done\|shipped\|closed' | head -1)"
    if [[ -n "$gapdone" ]]; then
        echo "  #$pr SUPERSEDED — gap $gap is $gapdone; work is already on main → CLOSE. ($title)"
        n_super=$((n_super+1)); emit pr_triage_verdict "$pr" superseded "gap-$gap-$gapdone"
        [[ $APPLY -eq 1 ]] && gh pr close "$pr" --comment "Triage: superseded — $gap already done on main. Closing so it stops sitting. (pr-triage-reporter)" >/dev/null 2>&1
        continue
    fi

    # no real failures + BEHIND → rebaser owns it
    if [[ -z "$fails" && "$ms" == "BEHIND" ]]; then
        echo "  #$pr BEHIND main (${age_h}h) — needs rebase; owned by pr-auto-rebase. ($title)"
        n_behind=$((n_behind+1)); emit pr_triage_verdict "$pr" behind "needs-rebase"; continue
    fi
    if [[ "$ms" == "DIRTY" ]]; then
        echo "  #$pr DIRTY (${age_h}h) — merge conflict, needs rebase/rework. gap=$gap ($title)"
        n_behind=$((n_behind+1)); emit pr_triage_verdict "$pr" conflict "dirty-needs-rebase"; continue
    fi

    # real failing checks → BROKEN-but-valuable → make fixing it a PRIORITY
    if [[ -n "$fails" ]]; then
        echo "  #$pr BROKEN (${age_h}h) — real CI failures: $fails. gap=$gap → PRIORITIZE FIX. ($title)"
        n_broken=$((n_broken+1)); emit pr_triage_verdict "$pr" broken "$fails"
        if [[ $APPLY -eq 1 && ! -f "$COOLDOWN/pr-$pr" ]]; then
            (cd "$REPO_ROOT" && chump gap reserve --domain EFFECTIVE --priority P1 --no-outcome-required \
              --title "EFFECTIVE: [triage] fix PR #$pr ($gap) — real CI failures ($fails) keeping valuable work off main" 2>/dev/null | grep -oiE 'EFFECTIVE-[0-9]+' | head -1 > "$COOLDOWN/pr-$pr")
            echo "     → filed P1 fix gap $(cat "$COOLDOWN/pr-$pr" 2>/dev/null) (once; cooldown set)"
        fi
        continue
    fi

    echo "  #$pr $ms (${age_h}h) — pending/other. ($title)"; n_pending=$((n_pending+1))
done

echo "=== SUMMARY: superseded=$n_super broken=$n_broken behind=$n_behind flaky=$n_flaky pending=$n_pending ok=$n_ok ==="
emit pr_triage_summary 0 rollup "super=$n_super broken=$n_broken behind=$n_behind"
