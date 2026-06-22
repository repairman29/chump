#!/usr/bin/env bash
# scripts/coord/wedge-recover.sh — MISSION-006 D2
#
# Automated wedge recovery. Runs the 4-step recovery playbook from the
# 2026-05-25 case study:
#
#   STEP 1: Refresh runner binary (if W-002 cache lag detected)
#   STEP 2: Local-rebase any DIRTY PRs (handles W-001 false-positives via INFRA-1958)
#   STEP 3: Retrigger failed CI on any PR whose last run is in 'failure' state
#   STEP 4: Cherry-pick orphans from reflog if any branches got force-push-stomped (W-006)
#
# Each step is idempotent and safe to re-run. The script emits ambient events
# so the operator can verify what fired.
#
# Usage:
#   scripts/coord/wedge-recover.sh                # full sequence
#   scripts/coord/wedge-recover.sh --dry-run      # print what would happen
#   scripts/coord/wedge-recover.sh --step N       # run only step N (1-4)
#   scripts/coord/wedge-recover.sh --json         # structured output
#
# Bypass: CHUMP_SKIP_WEDGE_RECOVER=1 short-circuits to exit 0.
#
# Pairs with: scripts/coord/wedge-watch.sh (detection),
# docs/process/WEDGE_CLASS_CATALOG.md (class definitions + manual playbooks).

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
DRY_RUN=0
ONLY_STEP=0
FORMAT=text

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --step) shift; ONLY_STEP="$1" ;;
        --step=*) ONLY_STEP="${1#*=}" ;;
        --json) FORMAT=json ;;
        --help|-h)
            head -22 "$0" | grep '^#' | sed 's/^# //; s/^#//'
            exit 0
            ;;
    esac
    shift
done

if [[ "${CHUMP_SKIP_WEDGE_RECOVER:-0}" == "1" ]]; then
    echo "BYPASS: CHUMP_SKIP_WEDGE_RECOVER=1"
    exit 0
fi

cd "$REPO_ROOT" || { echo "FATAL: cannot cd to $REPO_ROOT"; exit 2; }

# Result tracking
STEPS_RUN=()
emit_event() {
    [[ "$DRY_RUN" -eq 1 ]] && return
    local kind="$1" step="$2" extra="${3:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"step\":\"$step\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"step\":\"$step\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
run_step() {
    local n="$1"
    [[ "$ONLY_STEP" -ne 0 && "$ONLY_STEP" -ne "$n" ]] && return 1
    return 0
}

# ── STEP 1: refresh runner binary if stale ────────────────────────────────────
if run_step 1; then
    log "STEP 1: check runner binary freshness"
    git fetch origin main --quiet 2>/dev/null
    main_sha=$(git rev-parse --short=12 origin/main 2>/dev/null || echo "")
    installed_sha=""
    if [[ -x /opt/homebrew/bin/chump ]]; then
        installed_sha=$(/opt/homebrew/bin/chump --version 2>/dev/null | grep -oE '\([a-f0-9]+ built' | head -1 | sed 's/[( ]//g;s/built//')
    fi
    if [[ -n "$installed_sha" && -n "$main_sha" && "$installed_sha" != "$main_sha"* && "$main_sha" != "$installed_sha"* ]]; then
        log "  binary stale ($installed_sha vs main $main_sha) — invoking refresh-runner-binary.sh"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "  DRY-RUN: would run scripts/setup/refresh-runner-binary.sh"
            STEPS_RUN+=("step1=dry-run-stale")
        elif bash "$REPO_ROOT/scripts/setup/refresh-runner-binary.sh" 2>&1 | tail -3; then
            log "  refresh OK"
            STEPS_RUN+=("step1=refreshed")
            emit_event wedge_recover step1 "\"action\":\"binary_refreshed\",\"prev_sha\":\"$installed_sha\",\"main_sha\":\"$main_sha\""
        else
            log "  refresh FAILED — manual: cargo install --path . --bin chump --force; cp ~/.cargo/bin/chump /opt/homebrew/bin/chump"
            STEPS_RUN+=("step1=refresh-failed")
        fi
    else
        log "  binary fresh ($installed_sha matches main $main_sha) — skip"
        STEPS_RUN+=("step1=already-fresh")
    fi
fi

# ── STEP 2: local-rebase any DIRTY PRs ────────────────────────────────────────
if run_step 2; then
    log "STEP 2: local-rebase DIRTY PRs"
    dirty_prs=$(gh pr list --state open --json number,mergeStateStatus,headRefName --limit 60 2>/dev/null | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    if p.get('mergeStateStatus') == 'DIRTY':
        print(p['number'], p['headRefName'])
" 2>/dev/null)
    if [[ -z "$dirty_prs" ]]; then
        log "  no DIRTY PRs"
        STEPS_RUN+=("step2=clean")
    else
        rebased=0
        truly_conflict=0
        while read -r pr br; do
            [[ -z "$pr" ]] && continue
            log "  PR #$pr ($br): attempt local rebase"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "    DRY-RUN: would worktree-rebase + force-with-lease"
                continue
            fi
            wt="/tmp/wr-rebase-$pr"
            rm -rf "$wt" 2>/dev/null
            git fetch origin "$br" main --quiet 2>/dev/null
            if git worktree add "$wt" "origin/$br" >/dev/null 2>&1; then
                # INFRA-1526: plain rebase — no -X theirs. -X theirs silently
                # discards feature-branch hunks, causing orphan CI failures
                # (PR #2216 lost 173 lines; PR #2173 lost EVENT_REGISTRY entry).
                # The union/append merge drivers in .gitattributes handle
                # mechanical conflicts (Cargo.lock, EVENT_REGISTRY, etc.) cleanly.
                # Any remaining conflict needs manual resolution, not silent discard.
                if (cd "$wt" && git rebase origin/main >/dev/null 2>&1); then
                    # Verify no file lost all its substantial additions (INFRA-1526)
                    VERIFY_SCRIPT="$REPO_ROOT/scripts/coord/post-rebase-verify.sh"
                    if [[ -x "$VERIFY_SCRIPT" ]] && ! (cd "$wt" && AMBIENT="$AMBIENT" CHUMP_REPO_ROOT="$wt" bash "$VERIFY_SCRIPT" >/dev/null 2>&1); then
                        log "    rebase succeeded but hunk-drop detected — aborting push (INFRA-1526)"
                        emit_event wedge_recover step2 "\"action\":\"hunk_drop_blocked\",\"pr\":$pr"
                        git worktree remove "$wt" --force >/dev/null 2>&1 || true
                        continue
                    fi
                    if (cd "$wt" && git push origin "HEAD:$br" --force-with-lease >/dev/null 2>&1); then
                        rebased=$((rebased+1))
                        log "    rebased + pushed"
                        emit_event wedge_recover step2 "\"action\":\"rebased\",\"pr\":$pr"
                    fi
                else
                    (cd "$wt" && git rebase --abort 2>/dev/null) || true
                    truly_conflict=$((truly_conflict+1))
                    log "    true conflict — manual needed"
                fi
                git worktree remove "$wt" --force >/dev/null 2>&1 || true
            fi
        done <<< "$dirty_prs"
        STEPS_RUN+=("step2=rebased:$rebased,conflict:$truly_conflict")
    fi
fi

# ── STEP 3: retrigger CI on PRs whose latest run is in failure state ──────────
if run_step 3; then
    log "STEP 3: retrigger failed CI"
    retriggered=0
    skipped=0
    for pr in $(gh pr list --state open --json number --limit 60 -q '.[].number' 2>/dev/null); do
        rid=$(gh pr checks "$pr" --json link,bucket 2>/dev/null | python3 -c "
import json, sys, re
for c in json.load(sys.stdin):
    if c.get('bucket') == 'fail':
        m = re.search(r'/runs/(\d+)/', c.get('link', ''))
        if m: print(m.group(1)); break
" 2>/dev/null | head -1)
        if [[ -z "$rid" ]]; then
            skipped=$((skipped+1))
            continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "  DRY-RUN: would rerun CI run $rid on PR #$pr"
            continue
        fi
        if gh run rerun "$rid" --failed >/dev/null 2>&1; then
            retriggered=$((retriggered+1))
            log "  PR #$pr: rerun $rid"
            emit_event wedge_recover step3 "\"action\":\"retriggered\",\"pr\":$pr,\"run\":$rid"
        fi
    done
    STEPS_RUN+=("step3=retriggered:$retriggered,skipped:$skipped")
    log "  retriggered=$retriggered skipped=$skipped"
fi

# ── STEP 4: cherry-pick orphans from reflog for stomped branches ──────────────
if run_step 4; then
    log "STEP 4: scan for stomped branches (closed-unmerged with ahead=0)"
    git fetch origin main --quiet 2>/dev/null
    # Look at closed-but-not-merged PRs in last 1h
    cutoff="$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600))' 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"
    stomped=$(gh pr list --state closed --search "closed:>=$cutoff" --json number,mergedAt,headRefName --limit 30 2>/dev/null | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    if not p.get('mergedAt'):
        print(p['number'], p.get('headRefName',''))
" 2>/dev/null)
    if [[ -z "$stomped" ]]; then
        log "  no closed-unmerged PRs in last 1h"
        STEPS_RUN+=("step4=clean")
    else
        recovered=0
        while read -r pr br; do
            [[ -z "$pr" ]] && continue
            git fetch origin "$br" --quiet 2>/dev/null
            ahead=$(git rev-list --count "origin/main..origin/$br" 2>/dev/null || echo 0)
            if [[ "$ahead" -ne 0 ]]; then
                log "  PR #$pr ($br): ahead=$ahead — not stomped, skip"
                continue
            fi
            log "  PR #$pr ($br): ahead=0 vs main — possible stomp"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "    DRY-RUN: would search reflog for orphan + cherry-pick -X theirs"
                continue
            fi
            # Find orphan commit by gap ID in the PR title
            gap_id=$(gh pr view "$pr" --json title -q .title 2>/dev/null | grep -oE '\b[A-Z]+-[0-9]+\b' | head -1)
            if [[ -z "$gap_id" ]]; then
                log "    no gap ID in PR title — manual recovery needed"
                continue
            fi
            orphan_sha=$(git log --all --oneline --grep="$gap_id" 2>/dev/null | head -1 | awk '{print $1}')
            if [[ -z "$orphan_sha" ]]; then
                log "    no orphan commit found for $gap_id — manual recovery needed"
                continue
            fi
            log "    candidate orphan: $orphan_sha (mentions $gap_id)"
            wt="/tmp/wr-recover-$pr"
            rm -rf "$wt" 2>/dev/null
            git worktree add "$wt" origin/main >/dev/null 2>&1 || { log "    worktree fail"; continue; }
            if (cd "$wt" && git cherry-pick -X theirs "$orphan_sha" >/dev/null 2>&1); then
                if (cd "$wt" && git push origin "HEAD:$br" --force-with-lease >/dev/null 2>&1); then
                    recovered=$((recovered+1))
                    log "    recovered $orphan_sha → $br (PR #$pr can be reopened or fresh-created)"
                    emit_event wedge_recover step4 "\"action\":\"orphan_recovered\",\"pr\":$pr,\"orphan_sha\":\"$orphan_sha\""
                fi
            else
                (cd "$wt" && git cherry-pick --abort 2>/dev/null) || true
                log "    cherry-pick failed — manual needed"
            fi
            git worktree remove "$wt" --force >/dev/null 2>&1 || true
        done <<< "$stomped"
        STEPS_RUN+=("step4=recovered:$recovered")
    fi
fi

# ── Final report ──────────────────────────────────────────────────────────────
echo
log "RECOVERY COMPLETE"
for s in "${STEPS_RUN[@]}"; do
    echo "  $s"
done

if [[ "$FORMAT" == "json" ]]; then
    printf '{"steps":['
    sep=""
    for s in "${STEPS_RUN[@]}"; do
        printf '%s"%s"' "$sep" "$s"; sep=","
    done
    printf ']}\n'
fi

exit 0
