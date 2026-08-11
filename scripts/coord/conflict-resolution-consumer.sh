#!/usr/bin/env bash
# conflict-resolution-consumer.sh — RESILIENT-301.
#
# armed-pr-rebaser.sh (INFRA-3473) EMITS armed_pr_needs_conflict_resolution
# when a real conflict blocks a clean rebase, but nothing CONSUMES it — the
# only reference in the tree was the producer. Result: real-conflict PRs
# rotted with no owner (#3621 sat 18h; #3655 was green-but-DIRTY+unarmed and
# no organ even looked at it).
#
# This is the standing consumer / accountability organ for the merge-SLA:
#   1. Pick up PRs flagged via armed_pr_needs_conflict_resolution in
#      ambient.jsonl, PLUS open PRs that are green (all checks pass),
#      mergeStateStatus=DIRTY, and have no auto-merge armed (the class
#      #3655 fell into — nobody had even flagged them).
#   2. Try a plain rebase first (cheap — most DIRTY PRs are stale-behind,
#      not real conflicts). If clean: push + arm.
#   3. If a real conflict remains, dispatch conflict-resolver-agent.sh
#      (INFRA-1488) against the gap that owns the branch. If it resolves
#      + the rebase continues cleanly: push + arm.
#   4. Track attempts per PR in .chump-locks/conflict-resolution-attempts/.
#      After CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS (default 3) failed
#      rounds, escalate to the operator (broadcast + ambient) with the
#      PR#, age, and reason — then stop retrying until a human clears it
#      (state file removed or PR merged/closed).
#
# Usage: run standing via launchd (scripts/setup/install-conflict-resolution-consumer-launchd.sh)
#        or manually: bash scripts/coord/conflict-resolution-consumer.sh
#
# Env:
#   CHUMP_PR_REPO                          default repairman29/chump
#   CHUMP_REPO_ROOT                        default $HOME/Projects/Chump
#   CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS   default 3
#   CHUMP_CONFLICT_RESOLVER_ENABLED        forwarded to conflict-resolver-agent.sh (default 1 here —
#                                           this IS the standing owner of that capability)
set -uo pipefail

REPO="${CHUMP_PR_REPO:-repairman29/chump}"
ROOT="${CHUMP_REPO_ROOT:-$HOME/Projects/Chump}"
AMB="$ROOT/.chump-locks/ambient.jsonl"
STATE_DIR="$ROOT/.chump-locks/conflict-resolution-attempts"
MAX_ATTEMPTS="${CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS:-3}"
RESOLVER="$ROOT/scripts/coord/conflict-resolver-agent.sh"
BROADCAST="$ROOT/scripts/coord/broadcast.sh"

cd "$ROOT" 2>/dev/null || exit 1
command -v gh >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || true
git fetch origin main --quiet 2>/dev/null || true

# shellcheck disable=SC1091
. "$ROOT/scripts/coord/lib/github.sh" 2>/dev/null || true  # INFRA-1080: chump_gh throttling for the arm call

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# INFRA-1274: route the mutating merge/arm call through chump_gh (throttled +
# classified) when the lib sourced; fall back to plain gh otherwise. A bare
# `gh pr merge ...` line here trips the raw-gh-in-hot-paths lint gate.
_arm_pr() {
    local num="$1"
    if command -v chump_gh >/dev/null 2>&1; then
        chump_gh pr merge "$num" --repo "$REPO" --auto --squash >/dev/null 2>&1
    else
        command gh pr merge "$num" --repo "$REPO" --auto --squash >/dev/null 2>&1
    fi
}

_emit() {
    local kind="$1" body="$2"
    printf '{"ts":"%s","kind":"%s","body":%s}\n' "$(_ts)" "$kind" "$body" >> "$AMB" 2>/dev/null || true
}

# ── candidate discovery ────────────────────────────────────────────────────
# 1. PRs flagged via armed_pr_needs_conflict_resolution (from armed-pr-rebaser.sh)
#    that are STILL open — dedup to latest sighting per PR.
flagged="$(python3 - "$AMB" <<'PY' 2>/dev/null
import json, sys
path = sys.argv[1]
seen = {}
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("kind") != "armed_pr_needs_conflict_resolution":
                continue
            pr = ev.get("pr")
            br = ev.get("branch")
            if pr is None:
                continue
            seen[str(pr)] = br or ""
except FileNotFoundError:
    pass
for pr, br in seen.items():
    print(f"{pr}\t{br}")
PY
)"

# 2. Open PRs that are green + DIRTY + unarmed — nobody has even flagged these.
green_dirty="$(gh pr list --repo "$REPO" --state open \
        --json number,headRefName,mergeStateStatus,autoMergeRequest,statusCheckRollup 2>/dev/null \
    | python3 -c "import sys,json
for p in json.load(sys.stdin):
    if p.get('mergeStateStatus') != 'DIRTY':
        continue
    if p.get('autoMergeRequest'):
        continue
    checks = p.get('statusCheckRollup') or []
    if not checks:
        continue
    if all((c.get('conclusion') in ('SUCCESS','NEUTRAL','SKIPPED') or c.get('status') in ('SUCCESS','NEUTRAL')) for c in checks):
        print(p['number'], p.get('headRefName',''), sep='\t')" 2>/dev/null)"

candidates="$(printf '%s\n%s\n' "$flagged" "$green_dirty" | awk -F'\t' 'NF>=1 && $1!="" && !seen[$1]++')"

if [ -z "$(echo "$candidates" | tr -d '[:space:]')" ]; then
    exit 0
fi

resolved_count=0
escalated_count=0
attempted_count=0

while IFS=$'\t' read -r num br; do
    [ -z "$num" ] && continue
    attempted_count=$((attempted_count + 1))

    # PR may have closed/merged between flagging and now — skip if gone.
    state="$(gh pr view "$num" --repo "$REPO" --json state,headRefName,mergeStateStatus 2>/dev/null)"
    [ -z "$state" ] && continue
    pr_state="$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('state',''))" 2>/dev/null)"
    if [ "$pr_state" != "OPEN" ]; then
        rm -f "$STATE_DIR/$num.json" 2>/dev/null || true
        continue
    fi
    if [ -z "$br" ]; then
        br="$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('headRefName',''))" 2>/dev/null)"
    fi
    [ -z "$br" ] && continue

    state_file="$STATE_DIR/$num.json"
    attempts=0
    first_seen="$(_ts)"
    if [ -f "$state_file" ]; then
        attempts="$(python3 -c "import json;print(json.load(open('$state_file')).get('attempts',0))" 2>/dev/null || echo 0)"
        first_seen="$(python3 -c "import json;print(json.load(open('$state_file')).get('first_seen','$(_ts)'))" 2>/dev/null || _ts)"
    fi

    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        already_escalated="$(python3 -c "import json;print(json.load(open('$state_file')).get('escalated_at',''))" 2>/dev/null || echo "")"
        if [ -z "$already_escalated" ]; then
            age_secs=$(( $(date -u +%s) - $(date -u -d "$first_seen" +%s 2>/dev/null || date -u +%s) ))
            age_hrs=$(( age_secs / 3600 ))
            reason="unresolvable after $attempts attempts (plain rebase + conflict-resolver-agent both failed)"
            # scanner-anchor: "kind":"conflict_resolution_consumer_escalated"
            _emit "conflict_resolution_consumer_escalated" \
                "{\"pr\":$num,\"branch\":\"$br\",\"attempts\":$attempts,\"age_hrs\":$age_hrs,\"reason\":\"$reason\"}"
            if [ -x "$BROADCAST" ]; then
                "$BROADCAST" ALERT "kind=conflict_resolution_stalled" \
                    "PR #$num ($br) unresolvable after $attempts attempts, age ${age_hrs}h: $reason — needs operator" \
                    2>/dev/null || true
            fi
            python3 -c "
import json
json.dump({'pr':$num,'attempts':$attempts,'first_seen':'$first_seen','escalated_at':'$(_ts)'}, open('$state_file','w'))
" 2>/dev/null || true
            escalated_count=$((escalated_count + 1))
        fi
        continue
    fi

    git fetch origin "$br" --quiet 2>/dev/null || continue
    wt="/tmp/conflict-resolution-consumer-$num"
    git worktree remove "$wt" --force 2>/dev/null || true
    git worktree add "$wt" "$br" >/dev/null 2>&1 || continue

    outcome="fail"
    (
        cd "$wt" || exit 1
        if git rebase origin/main >/dev/null 2>&1 \
           && [ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
            echo clean
        else
            echo conflict
        fi
    ) > "$wt.status" 2>/dev/null
    status_line="$(cat "$wt.status" 2>/dev/null || echo fail)"
    rm -f "$wt.status" 2>/dev/null || true

    if [ "$status_line" = "clean" ]; then
        if (cd "$wt" && git push origin "$br" --force-with-lease >/dev/null 2>&1); then
            _arm_pr "$num" || true
            # scanner-anchor: "kind":"conflict_resolution_consumer_rebase_clean"
            _emit "conflict_resolution_consumer_rebase_clean" "{\"pr\":$num,\"branch\":\"$br\"}"
            echo "[conflict-resolution-consumer] #$num: plain rebase clean, pushed + armed"
            rm -f "$state_file" 2>/dev/null || true
            resolved_count=$((resolved_count + 1))
            outcome="clean"
        fi
    else
        (cd "$wt" && git rebase --abort 2>/dev/null || true)
        gap_id="$(echo "$br" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | head -1)"
        if [ -n "$gap_id" ] && [ -x "$RESOLVER" ]; then
            (cd "$wt" && git rebase origin/main >/dev/null 2>&1) || true
            if (cd "$wt" && REPO_ROOT="$wt" GAP_ID="$gap_id" \
                    CHUMP_CONFLICT_RESOLVER_ENABLED="${CHUMP_CONFLICT_RESOLVER_ENABLED:-1}" \
                    CHUMP_AMBIENT_LOG="$AMB" "$RESOLVER" "$gap_id" >/dev/null 2>&1); then
                if (cd "$wt" && git push origin "$br" --force-with-lease >/dev/null 2>&1); then
                    _arm_pr "$num" || true
                    # scanner-anchor: "kind":"conflict_resolution_consumer_resolved"
                    _emit "conflict_resolution_consumer_resolved" "{\"pr\":$num,\"branch\":\"$br\",\"gap_id\":\"$gap_id\"}"
                    echo "[conflict-resolution-consumer] #$num: conflict-resolver-agent resolved, pushed + armed"
                    rm -f "$state_file" 2>/dev/null || true
                    resolved_count=$((resolved_count + 1))
                    outcome="clean"
                fi
            fi
            (cd "$wt" && git rebase --abort 2>/dev/null || true)
        fi

        if [ "$outcome" != "clean" ]; then
            attempts=$((attempts + 1))
            python3 -c "
import json
json.dump({'pr':$num,'attempts':$attempts,'first_seen':'$first_seen'}, open('$state_file','w'))
" 2>/dev/null || true
            echo "[conflict-resolution-consumer] #$num: still conflicted, attempt $attempts/$MAX_ATTEMPTS"
        fi
    fi

    git worktree remove "$wt" --force 2>/dev/null || true
done <<< "$candidates"

# scanner-anchor: "kind":"conflict_resolution_consumer_tick"
_emit "conflict_resolution_consumer_tick" \
    "{\"candidates\":$attempted_count,\"resolved\":$resolved_count,\"escalated\":$escalated_count}"
