#!/usr/bin/env bash
# pr-watch-shepherd.sh — INFRA-354: scan all open ARMED PRs and auto-recover
# DIRTY-after-arm ones via pr-watch.sh, regardless of whether the original
# author's worktree / agent is still alive.
#
# Background:
#   pr-watch.sh (INFRA-190) auto-recovers a single PR (disarm → fetch →
#   rebase → force-push → re-arm) when its mergeStateStatus goes DIRTY
#   after auto-merge was armed. Today it's invoked by bot-merge.sh as a
#   detached background process per PR. When the host cycles or the
#   author's worktree is reaped, pr-watch dies with the PR still DIRTY.
#   Observed 2026-05-02: 4 PRs (#947 #950 #959 #961) all DIRTY-after-arm
#   for 25-50min with nobody picking them up.
#
# This shepherd runs as a launchd job every 10 min. For each open ARMED
# PR with mergeStateStatus=DIRTY, it:
#   1. Checks the cooldown (skip if same head_sha was tried recently and failed)
#   2. Spins up an ephemeral worktree at the PR's branch
#   3. Runs `pr-watch.sh <PR#> --once` in that worktree
#   4. Records cooldown on rebase-conflict failure
#   5. Removes the ephemeral worktree
#
# Emits one `pr_watch_run` event to ambient.jsonl per pass with summary
# counts (scanned/recovered/cooldown/conflict). Stamps a heartbeat file
# at /tmp/chump-reaper-pr-watch.heartbeat for the watchdog.
#
# Exit codes:
#   0  ran cleanly (work done or nothing to do)
#   1  precondition failure (gh missing, repo not detected)
#
# Env:
#   CHUMP_PR_WATCH_SHEPHERD=0  bypass — exit 0 immediately (for tests)
#   PR_WATCH_COOLDOWN_S        seconds before retrying same head_sha (default 3600)
#   PR_WATCH_MAX_PRS           cap PRs processed per run (default 20, safety valve)

set -euo pipefail

if [[ "${CHUMP_PR_WATCH_SHEPHERD:-1}" == "0" ]]; then
    echo "[pr-watch-shepherd] CHUMP_PR_WATCH_SHEPHERD=0 — bypass"
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "[pr-watch-shepherd] not in a git checkout — exit 1" >&2
    exit 1
fi
cd "$REPO_ROOT"

# Resolve the MAIN repo root for shared state (.chump-locks/) — when run
# from a linked worktree, --show-toplevel gives the worktree but ambient.jsonl
# lives in the main worktree's .chump-locks/. --git-common-dir's parent is
# the main worktree (or `.git` literally if we ARE the main).
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
if [[ "$COMMON_DIR" == ".git" || "$COMMON_DIR" == "$REPO_ROOT/.git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$COMMON_DIR/.." && pwd)"
fi

if ! command -v gh >/dev/null; then
    echo "[pr-watch-shepherd] gh CLI not found — exit 1" >&2
    exit 1
fi

PR_WATCH="$REPO_ROOT/scripts/coord/pr-watch.sh"
[[ -x "$PR_WATCH" ]] || { echo "[pr-watch-shepherd] $PR_WATCH not executable — exit 1" >&2; exit 1; }

COOLDOWN_S="${PR_WATCH_COOLDOWN_S:-3600}"
MAX_PRS="${PR_WATCH_MAX_PRS:-20}"
COOLDOWN_DIR="/tmp/chump-pr-watch-cooldown"
mkdir -p "$COOLDOWN_DIR"

AMBIENT="$MAIN_REPO/.chump-locks/ambient.jsonl"
HEARTBEAT="/tmp/chump-reaper-pr-watch.heartbeat"

# Stamp heartbeat at start so the watchdog knows we ran (even if we crash mid-pass).
date -u +%Y-%m-%dT%H:%M:%SZ > "$HEARTBEAT"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit_ambient() {
    # $1 = JSON object body (no leading {, no trailing }). Caller provides
    # quoted keys, e.g. '"scanned":3,"recovered":2'. Do not pre-open a quote
    # in the format string — that confused the first version (INFRA-354).
    [[ -d "$(dirname "$AMBIENT")" ]] || return 0
    printf '{"ts":"%s","event":"reaper_run","kind":"pr_watch",%s}\n' "$(ts)" "$1" >> "$AMBIENT"
}

# 1. Discover open ARMED PRs that are currently DIRTY.
#    Using --json + python filter rather than --search 'is:open auto-merge:enabled'
#    because that search filter isn't always honored consistently by the API.
#    Avoiding `mapfile` because launchd's `/bin/bash -lc` runs bash 3.2 on macOS
#    (mapfile is bash 4+). Read into a newline-delimited string + word-split.
TARGETS_RAW="$(
    gh pr list --state open --limit 100 --json number,headRefName,mergeStateStatus,autoMergeRequest,headRefOid \
        2>/dev/null \
    | python3 -c '
import json, sys
prs = json.load(sys.stdin)
for p in prs:
    if p.get("mergeStateStatus") != "DIRTY": continue
    if not p.get("autoMergeRequest"): continue
    n, br, sha = p["number"], p["headRefName"], p["headRefOid"][:12]
    print(f"{n}|{br}|{sha}")
' 2>/dev/null
)"

# Count non-empty lines (avoids treating empty TARGETS_RAW as one entry)
SCANNED=0
[[ -n "$TARGETS_RAW" ]] && SCANNED=$(printf '%s\n' "$TARGETS_RAW" | wc -l | tr -d ' ')
RECOVERED=0
COOLDOWN=0
CONFLICT=0
ERRORS=0

if (( SCANNED == 0 )); then
    emit_ambient "\"scanned\":0,\"recovered\":0,\"cooldown\":0,\"conflict\":0,\"status\":\"ok\""
    echo "[pr-watch-shepherd] no DIRTY-after-arm PRs found"
    exit 0
fi

echo "[pr-watch-shepherd] scanning $SCANNED DIRTY-after-arm PR(s) (cap=$MAX_PRS)"

PROCESSED=0
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    (( PROCESSED >= MAX_PRS )) && break
    PROCESSED=$((PROCESSED + 1))

    IFS='|' read -r PR BRANCH HEAD_SHA <<< "$entry"
    cooldown_marker="$COOLDOWN_DIR/${PR}-${HEAD_SHA}"

    # Cooldown check: same head_sha failed recently → skip
    if [[ -f "$cooldown_marker" ]]; then
        marker_age=$(( $(date +%s) - $(stat -f %m "$cooldown_marker" 2>/dev/null || stat -c %Y "$cooldown_marker" 2>/dev/null || echo 0) ))
        if (( marker_age < COOLDOWN_S )); then
            echo "[pr-watch-shepherd] skip PR #$PR (cooldown: ${marker_age}s < ${COOLDOWN_S}s)"
            COOLDOWN=$((COOLDOWN + 1))
            continue
        fi
        # Cooldown expired — remove marker and try again
        rm -f "$cooldown_marker"
    fi

    # 2. Ephemeral worktree at PR's branch
    WT="/tmp/chump-pr-watch-pr${PR}-$$"
    if ! git fetch origin "$BRANCH" --quiet 2>/dev/null; then
        echo "[pr-watch-shepherd] PR #$PR: fetch failed — skip"
        ERRORS=$((ERRORS + 1))
        continue
    fi
    if ! git worktree add -B "tmp-shepherd-pr$PR" "$WT" "origin/$BRANCH" >/dev/null 2>&1; then
        echo "[pr-watch-shepherd] PR #$PR: worktree add failed — skip"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # 3. Run pr-watch in the ephemeral worktree.
    #    pr-watch.sh checks `git symbolic-ref` so we need a real branch ref;
    #    `git worktree add -B` gave us tmp-shepherd-prN but pr-watch will
    #    refuse because branch name != PR's headRefName. Re-checkout under
    #    the real branch name (it now exists locally as origin/BRANCH).
    pushd "$WT" >/dev/null
    git checkout -B "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1 || true
    set +e
    bash "$PR_WATCH" "$PR" --once
    rc=$?
    set -e
    popd >/dev/null

    case "$rc" in
        0)
            echo "[pr-watch-shepherd] PR #$PR: recovered"
            RECOVERED=$((RECOVERED + 1))
            ;;
        3)
            echo "[pr-watch-shepherd] PR #$PR: rebase conflict — recording cooldown ($COOLDOWN_S s)"
            : > "$cooldown_marker"
            CONFLICT=$((CONFLICT + 1))
            ;;
        *)
            echo "[pr-watch-shepherd] PR #$PR: pr-watch exit $rc — recording cooldown to avoid thrash"
            : > "$cooldown_marker"
            ERRORS=$((ERRORS + 1))
            ;;
    esac

    # 4. Cleanup ephemeral worktree (and the temp branch ref)
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git branch -D "tmp-shepherd-pr$PR" >/dev/null 2>&1 || true
done <<< "$TARGETS_RAW"

emit_ambient "\"scanned\":$SCANNED,\"processed\":$PROCESSED,\"recovered\":$RECOVERED,\"cooldown\":$COOLDOWN,\"conflict\":$CONFLICT,\"errors\":$ERRORS,\"status\":\"ok\""
echo "[pr-watch-shepherd] done: scanned=$SCANNED processed=$PROCESSED recovered=$RECOVERED cooldown=$COOLDOWN conflict=$CONFLICT errors=$ERRORS"
exit 0
