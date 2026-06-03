#!/usr/bin/env bash
# last-mile-rescuer.sh — INFRA-2629
#
# The CONSUMER side of orphan-worktree-watchdog (RESILIENT-026), plus two
# independent triggers that catch work dropped at the finish line before a
# sub-agent's push completes.
#
# Motivating incident (2026-06-03): Two Sonnet sub-agents committed work to
# /tmp worktrees that sat unpushed for hours. RESILIENT-058 nearly caused a
# double-push when orchestrator rescued work that Sonnet was mid-retry on.
# orphan-worktree-watchdog.sh DETECTS these events — this daemon ACTS on them.
#
# Three triggers:
#
#   Trigger 1: Consume kind=orphan_worktree_detected from ambient.jsonl
#     - Re-verify: worktree exists, branch ahead of origin/main, no open PR
#     - If verified: rebase onto fresh origin/main, push via bot-merge.sh
#     - Emit kind=last_mile_rescue_triggered / last_mile_rescue_completed / last_mile_rescue_failed
#
#   Trigger 2: Scan local claim branches for unpushed commits
#     - git branch --list 'chump/(INFRA|...)-[0-9]+-claim'
#     - Same verification + rescue path (catches orphan-watchdog misses)
#
#   Trigger 3: Detect stalled sub-agent dispatches (notification only, no push)
#     - Ambient events kind=sub_agent_dispatched older than CHUMP_LAST_MILE_AGENT_STALL_S
#       with no paired sub_agent_completed OR matching open PR
#     - Emit kind=last_mile_agent_stall_detected for operator audit
#
# Usage:
#   scripts/coord/last-mile-rescuer.sh               # normal daemon tick
#   scripts/coord/last-mile-rescuer.sh --dry-run     # intent-only, no push
#   scripts/coord/last-mile-rescuer.sh --trigger1-only  # orphan events only
#   scripts/coord/last-mile-rescuer.sh --trigger2-only  # branch scan only
#   scripts/coord/last-mile-rescuer.sh --trigger3-only  # stall detection only
#
# Emits:
#   kind=last_mile_rescue_triggered  — rescue attempt started
#   kind=last_mile_rescue_completed  — rescue succeeded (PR opened or auto-merge armed)
#   kind=last_mile_rescue_failed     — rescue couldn't proceed (rebase conflict, push refused)
#   kind=last_mile_agent_stall_detected — dispatched agent age exceeded threshold
#
# Environment:
#   CHUMP_LAST_MILE_DISABLED=1           — panic-stop; logs once, exits 0
#   CHUMP_LAST_MILE_DRY_RUN=1           — emit intent events, no actual push
#   CHUMP_LAST_MILE_AGENT_STALL_S       — stall threshold in seconds (default 1800)
#   CHUMP_LAST_MILE_ORPHAN_WINDOW_S     — ambient lookback window (default 600 = 10 min)
#   CHUMP_AMBIENT_LOG                   — override ambient.jsonl path
#   CHUMP_LOCK_DIR                      — override .chump-locks path
#   CHUMP_REPO_ROOT                     — override repo root detection
#
# Install:
#   cp .chump/launchd/com.chump.last-mile-rescuer.plist ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.chump.last-mile-rescuer.plist
#
# Do NOT:
#   - Modify orphan-worktree-watchdog.sh (RESILIENT-026) — you're a consumer
#   - Modify stale-pr-rebase-bot.sh (INFRA-2295) — it handles OPEN PRs; we handle never-pushed
#   - Auto-push without verification; always re-check branch state + PR existence
#
# scanner-anchor: "kind":"last_mile_rescue_triggered"
# scanner-anchor: "kind":"last_mile_rescue_completed"
# scanner-anchor: "kind":"last_mile_rescue_failed"
# scanner-anchor: "kind":"last_mile_agent_stall_detected"

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve REPO_ROOT: env override → git from script location → fallback
REPO_ROOT="${CHUMP_REPO_ROOT:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
        || git -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel 2>/dev/null \
        || echo "/Users/jeffadkins/Projects/Chump")"
fi

# When running inside a linked worktree, the git-common-dir points back to the
# main repo's .git — use that for operations that must target the main repo.
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" != ".git" && -d "$_GIT_COMMON/.." ]]; then
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
else
    MAIN_REPO="$REPO_ROOT"
fi

LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-last-mile-rescuer-$$}"
STALL_THRESHOLD_S="${CHUMP_LAST_MILE_AGENT_STALL_S:-1800}"
ORPHAN_WINDOW_S="${CHUMP_LAST_MILE_ORPHAN_WINDOW_S:-600}"
DRY_RUN="${CHUMP_LAST_MILE_DRY_RUN:-0}"
BOT_MERGE="$MAIN_REPO/scripts/coord/bot-merge.sh"

# Trigger flags (all enabled by default)
RUN_TRIGGER1=1
RUN_TRIGGER2=1
RUN_TRIGGER3=1

# ── Bypass ────────────────────────────────────────────────────────────────────

if [[ "${CHUMP_LAST_MILE_DISABLED:-0}" == "1" ]]; then
    echo "[last-mile-rescuer] CHUMP_LAST_MILE_DISABLED=1 — skipping tick" >&2
    exit 0
fi

# ── Args ──────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=1 ;;
        --trigger1-only)  RUN_TRIGGER2=0; RUN_TRIGGER3=0 ;;
        --trigger2-only)  RUN_TRIGGER1=0; RUN_TRIGGER3=0 ;;
        --trigger3-only)  RUN_TRIGGER1=0; RUN_TRIGGER2=0 ;;
        --lock-dir)       LOCK_DIR="$2"; AMBIENT="$LOCK_DIR/ambient.jsonl"; shift ;;
        --ambient-log)    AMBIENT="$2"; shift ;;
        --stall-s)        STALL_THRESHOLD_S="$2"; shift ;;
        --orphan-window)  ORPHAN_WINDOW_S="$2"; shift ;;
        -h|--help)
            sed -n '2,70p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "[last-mile-rescuer] unknown arg: $1" >&2
            exit 2
            ;;
    esac
    shift
done

mkdir -p "$LOCK_DIR"

NOW_EPOCH=$(date +%s)

# ── Helpers ───────────────────────────────────────────────────────────────────

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    local kind="$1"; shift
    local extra="${1:-}"
    local body
    if [[ -n "$extra" ]]; then
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s",%s}' \
            "$(_now_iso)" "$kind" "$SESSION_ID" "$extra")"
    else
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s"}' \
            "$(_now_iso)" "$kind" "$SESSION_ID")"
    fi
    printf '%s\n' "$body" >> "$AMBIENT" 2>/dev/null || true
    echo "[last-mile-rescuer] EMIT $kind" >&2
}

_log() { echo "[last-mile-rescuer] $*" >&2; }

# Parse ISO8601 date to epoch seconds (macOS + Linux compatible)
# NOTE: BSD date (macOS) ignores the Z suffix and uses local time unless
# TZ=UTC is set explicitly. Always force UTC to get correct epoch values.
_iso_to_epoch() {
    local iso="$1"
    # Strip trailing Z for BSD date format string compatibility
    local iso_stripped="${iso%Z}"
    if date --version >/dev/null 2>&1; then
        # GNU date — handles ISO8601 natively
        date -d "$iso" +%s 2>/dev/null || echo 0
    else
        # BSD date (macOS) — must force TZ=UTC; without it, local offset is applied
        TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$iso_stripped" +%s 2>/dev/null || echo 0
    fi
}

# Check whether an open PR exists for a given branch (cache-first per INFRA-1081)
_has_open_pr() {
    local branch="$1"
    local cache_lib="$MAIN_REPO/scripts/lib/github_cache.sh"

    # Try cache first
    if [[ -f "$cache_lib" ]]; then
        local cache_result
        # shellcheck source=../lib/github_cache.sh
        # shellcheck disable=SC1091
        if cache_result="$(source "$cache_lib" 2>/dev/null && \
                cache_query_open_prs 2>/dev/null | awk -F'\t' -v b="$branch" '$3==b{print $1}' | head -1)"; then
            if [[ -n "$cache_result" ]]; then
                return 0  # open PR found
            fi
            # Cache hit but no PR — trust it
            return 1
        fi
    fi

    # Cache miss — fall back to gh CLI (background criticality per INFRA-1080)
    local pr_num
    pr_num="$(CHUMP_GH_CALL_CRITICALITY=background \
        gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' \
        2>/dev/null || true)"
    [[ -n "$pr_num" ]]
}

# Count commits ahead of origin/main on a given branch (in given repo dir)
_commits_ahead() {
    local repo_dir="$1"
    local branch="${2:-HEAD}"
    # Fetch is intentionally skipped here — we only have local data.
    # The caller must ensure origin/main is fresh before calling (we do git fetch in rescue).
    local count
    count="$(git -C "$repo_dir" rev-list --count "origin/main..${branch}" 2>/dev/null || echo 0)"
    echo "$count"
}

# ── Trigger 1: Consume orphan_worktree_detected events ───────────────────────

_trigger1_orphan_events() {
    _log "Trigger 1: scanning ambient for orphan_worktree_detected events (window=${ORPHAN_WINDOW_S}s)"

    [[ -f "$AMBIENT" ]] || { _log "ambient.jsonl not found, skipping trigger 1"; return; }

    local cutoff_epoch
    cutoff_epoch=$(( NOW_EPOCH - ORPHAN_WINDOW_S ))

    local rescued=0 skipped=0

    while IFS= read -r line; do
        # Only process orphan_worktree_detected events
        echo "$line" | grep -q '"kind":"orphan_worktree_detected"' || continue

        # Extract fields with python3 (robust against embedded JSON quirks)
        local worktree_path branch gap_id event_ts
        worktree_path="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('worktree_path',''))" \
            2>/dev/null || true)"
        branch="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('branch',''))" \
            2>/dev/null || true)"
        gap_id="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); v=d.get('claim_gap_id'); print(v if v else '')" \
            2>/dev/null || true)"
        event_ts="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('ts',''))" \
            2>/dev/null || true)"

        [[ -n "$worktree_path" && -n "$branch" ]] || continue

        # Time filter: only events in the last ORPHAN_WINDOW_S seconds
        local event_epoch
        event_epoch="$(_iso_to_epoch "$event_ts")"
        [[ "$event_epoch" -ge "$cutoff_epoch" ]] || continue

        _log "Trigger 1: processing orphan event for $worktree_path (branch=$branch gap_id=${gap_id:-unknown})"
        # Pass the worktree path even if it no longer exists on disk.
        # _rescue_worktree will fall back to the main repo when wt_path is
        # absent — the branch name alone is sufficient to rebase + push.
        _rescue_worktree "$worktree_path" "$branch" "$gap_id" "trigger1_orphan_event" \
            && rescued=$(( rescued + 1 )) || skipped=$(( skipped + 1 ))

    done < "$AMBIENT"

    _log "Trigger 1 done: rescued=$rescued skipped=$skipped"
}

# ── Trigger 2: Scan local claim branches for unpushed commits ────────────────

_trigger2_branch_scan() {
    _log "Trigger 2: scanning local claim branches for unpushed commits"

    # Fetch so our ahead-count is accurate
    git -C "$MAIN_REPO" fetch origin main --quiet 2>/dev/null || \
        _log "WARNING: git fetch failed — ahead-count may be stale"

    local rescued=0 skipped=0

    # Find all local claim branches matching the naming convention.
    # Git branch names are case-sensitive; include both uppercase (canonical
    # spec) and lowercase (what chump-commit.sh / sub-agents produce via `tr`)
    # so we catch both naming variants without false misses.
    local branches=()
    while IFS= read -r b; do
        [[ -n "$b" ]] && branches+=("$b")
    done < <(
        git -C "$MAIN_REPO" branch --list \
            'chump/INFRA-*-claim'      'chump/infra-*-claim' \
            'chump/RESILIENT-*-claim'  'chump/resilient-*-claim' \
            'chump/EFFECTIVE-*-claim'  'chump/effective-*-claim' \
            'chump/CREDIBLE-*-claim'   'chump/credible-*-claim' \
            'chump/ZERO-*-claim'       'chump/zero-*-claim' \
            'chump/META-*-claim'       'chump/meta-*-claim' \
            'chump/COG-*-claim'        'chump/cog-*-claim' \
            'chump/MISSION-*-claim'    'chump/mission-*-claim' \
            2>/dev/null | sed 's/^[* ]*//' | sort -u
    )

    if [[ ${#branches[@]} -eq 0 ]]; then
        _log "Trigger 2: no claim branches found"
        return
    fi

    _log "Trigger 2: checking ${#branches[@]} claim branch(es)"

    for branch in "${branches[@]}"; do
        # Derive gap_id from branch name: chump/INFRA-1234-claim → INFRA-1234
        local gap_id
        gap_id="$(echo "$branch" | sed 's|^chump/||; s|-claim$||')" || gap_id=""

        # Count commits ahead of origin/main
        local ahead
        ahead="$(_commits_ahead "$MAIN_REPO" "$branch")"
        if [[ "$ahead" -eq 0 ]]; then
            _log "Trigger 2: SKIP $branch — 0 commits ahead of origin/main"
            skipped=$(( skipped + 1 ))
            continue
        fi

        # Check for open PR — if one exists, bot-merge or human is handling it
        if _has_open_pr "$branch"; then
            _log "Trigger 2: SKIP $branch — open PR already exists"
            skipped=$(( skipped + 1 ))
            continue
        fi

        _log "Trigger 2: CANDIDATE $branch (ahead=$ahead, no open PR, gap_id=${gap_id:-unknown})"

        # Find the linked worktree checked out on this branch (if any).
        # Falls back to MAIN_REPO if none found — branch name alone is sufficient.
        local wt_path
        wt_path="$(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null \
            | awk -v br="refs/heads/${branch}" '
                /^worktree /{wt=$2}
                /^branch /{if($2==br) print wt}
            ' | head -1)"

        _rescue_worktree "${wt_path:-$MAIN_REPO}" "$branch" "$gap_id" "trigger2_branch_scan" \
            && rescued=$(( rescued + 1 )) || skipped=$(( skipped + 1 ))
    done

    _log "Trigger 2 done: rescued=$rescued skipped=$skipped"
}

# ── Rescue worker (shared between triggers 1 and 2) ───────────────────────────

_rescue_worktree() {
    local wt_path="$1"
    local branch="$2"
    local gap_id="${3:-}"
    local source_trigger="${4:-unknown}"

    # Re-verify: if the named worktree no longer exists on disk, fall back to
    # the main repo dir for the rebase+push — the branch is still local and
    # the name is sufficient to rescue.  Do NOT skip outright; the motivating
    # incident is exactly this case (worktree deleted, branch still present).
    local work_dir
    if [[ -n "$wt_path" && "$wt_path" != "$MAIN_REPO" && ! -d "$wt_path" ]]; then
        _log "NOTE: worktree $wt_path no longer on disk — falling back to main repo for rescue"
        work_dir="$MAIN_REPO"
    else
        work_dir="${wt_path:-$MAIN_REPO}"
    fi

    # Verify branch is actually checked out at work_dir (may be stale reference)
    local current_branch
    current_branch="$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [[ "$current_branch" != "$branch" && -n "$wt_path" && "$wt_path" != "$MAIN_REPO" ]]; then
        # Branch not checked out in this worktree — try main repo
        work_dir="$MAIN_REPO"
    fi

    # Fetch origin/main fresh before checking ahead-count
    git -C "$MAIN_REPO" fetch origin main --quiet 2>/dev/null || true

    # Verify ahead-count (double-check even after trigger already checked)
    local ahead
    ahead="$(_commits_ahead "$MAIN_REPO" "$branch")"
    if [[ "$ahead" -eq 0 ]]; then
        _log "SKIP $branch — 0 commits ahead of origin/main after re-verify"
        return 1
    fi

    # Verify no open PR (re-check to prevent double-push)
    if _has_open_pr "$branch"; then
        _log "SKIP $branch — open PR exists (re-verified), nothing to rescue"
        return 1
    fi

    local gap_field
    if [[ -n "$gap_id" ]]; then
        gap_field="\"gap_id\":\"${gap_id}\""
    else
        gap_field="\"gap_id\":null"
    fi

    # Emit rescue triggered
    _emit "last_mile_rescue_triggered" \
        "\"branch\":\"${branch}\",\"worktree_path\":\"${wt_path}\",${gap_field},\"source\":\"${source_trigger}\",\"commits_ahead\":${ahead},\"dry_run\":${DRY_RUN}"

    if [[ "$DRY_RUN" == "1" ]]; then
        _log "DRY_RUN: would rescue $branch ($ahead commits ahead) via bot-merge"
        return 0
    fi

    # Rebase onto fresh origin/main before push
    _log "Rebasing $branch onto origin/main..."
    if ! git -C "$MAIN_REPO" rebase "origin/main" "$branch" 2>/dev/null; then
        _log "ERROR: rebase conflict on $branch — filing STUCK, skipping push"
        _emit "last_mile_rescue_failed" \
            "\"branch\":\"${branch}\",${gap_field},\"reason\":\"rebase_conflict\",\"source\":\"${source_trigger}\""
        # Abort the rebase so it doesn't block future cycles
        git -C "$MAIN_REPO" rebase --abort 2>/dev/null || true
        return 1
    fi

    # Push via bot-merge.sh
    _log "Pushing $branch via bot-merge.sh..."
    local bm_args=("--auto-merge" "--fast")
    [[ -n "$gap_id" ]] && bm_args+=("--gap" "$gap_id")

    local bm_exit=0
    if [[ -f "$BOT_MERGE" ]]; then
        CHUMP_REPO_ROOT="$MAIN_REPO" \
        GIT_BRANCH="$branch" \
        bash "$BOT_MERGE" "${bm_args[@]}" 2>&1 | while IFS= read -r l; do _log "bot-merge: $l"; done \
            || bm_exit=$?
    else
        # Fallback: bare push + gh pr create
        _log "WARNING: bot-merge.sh not found at $BOT_MERGE — using bare push fallback"
        git -C "$MAIN_REPO" push -u origin "$branch" --force-with-lease 2>/dev/null || bm_exit=$?
        if [[ "$bm_exit" -eq 0 ]]; then
            gh pr create --base main --head "$branch" \
                --title "feat(${gap_id:-last-mile-rescue}): rescued unpushed work" \
                --body "Last-mile rescue: $ahead commits from $branch were never pushed. Auto-rescued by INFRA-2629." \
                2>/dev/null || true
        fi
    fi

    if [[ "$bm_exit" -ne 0 ]]; then
        _log "ERROR: push failed for $branch (exit=$bm_exit)"
        _emit "last_mile_rescue_failed" \
            "\"branch\":\"${branch}\",${gap_field},\"reason\":\"push_failed\",\"exit_code\":${bm_exit},\"source\":\"${source_trigger}\""
        return 1
    fi

    _log "SUCCESS: rescued $branch"
    _emit "last_mile_rescue_completed" \
        "\"branch\":\"${branch}\",\"worktree_path\":\"${wt_path}\",${gap_field},\"commits_ahead\":${ahead},\"source\":\"${source_trigger}\""
    return 0
}

# ── Trigger 3: Detect stalled sub-agent dispatches ───────────────────────────

_trigger3_stall_detection() {
    _log "Trigger 3: scanning for stalled sub-agent dispatches (threshold=${STALL_THRESHOLD_S}s)"

    [[ -f "$AMBIENT" ]] || { _log "ambient.jsonl not found, skipping trigger 3"; return; }

    local stall_count=0
    local cutoff_epoch
    cutoff_epoch=$(( NOW_EPOCH - STALL_THRESHOLD_S ))

    # Collect all dispatched agent ids that have a matching completion event or open PR
    # Build a set of "completed" gap_ids from sub_agent_completed events
    # (field name may be 'gap' per the sub_agent_dispatched schema)
    local completed_gaps=()
    while IFS= read -r line; do
        echo "$line" | grep -q '"kind":"sub_agent_completed"' || continue
        local g
        g="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('gap') or d.get('gap_id',''))" \
            2>/dev/null || true)"
        [[ -n "$g" ]] && completed_gaps+=("$g")
    done < "$AMBIENT"

    # Process dispatched events older than stall threshold
    while IFS= read -r line; do
        echo "$line" | grep -q '"kind":"sub_agent_dispatched"' || continue

        local gap_id agent_id dispatched_ts
        gap_id="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('gap') or d.get('gap_id',''))" \
            2>/dev/null || true)"
        agent_id="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('session') or d.get('agent_id',''))" \
            2>/dev/null || true)"
        dispatched_ts="$(echo "$line" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('ts',''))" \
            2>/dev/null || true)"

        [[ -n "$gap_id" && -n "$dispatched_ts" ]] || continue

        # Only check dispatches older than the stall threshold
        local dispatched_epoch
        dispatched_epoch="$(_iso_to_epoch "$dispatched_ts")"
        [[ "$dispatched_epoch" -lt "$cutoff_epoch" ]] || continue

        local elapsed_s
        elapsed_s=$(( NOW_EPOCH - dispatched_epoch ))

        # Check if already completed via ambient
        local is_completed=0
        for cg in "${completed_gaps[@]+"${completed_gaps[@]}"}"; do
            [[ "$cg" == "$gap_id" ]] && { is_completed=1; break; }
        done
        [[ "$is_completed" -eq 1 ]] && {
            _log "Trigger 3: SKIP $gap_id — found sub_agent_completed event"
            continue
        }

        # Check if an open PR exists for any claim branch matching the gap_id
        local gap_lc
        gap_lc="$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')"
        local candidate_branch="chump/${gap_lc}-claim"
        if _has_open_pr "$candidate_branch"; then
            _log "Trigger 3: SKIP $gap_id — open PR found on $candidate_branch"
            continue
        fi

        # Stall detected — emit notification (no auto-push for trigger 3)
        _log "STALL DETECTED: $gap_id dispatched at $dispatched_ts (${elapsed_s}s ago, no completion signal)"
        _emit "last_mile_agent_stall_detected" \
            "\"gap_id\":\"${gap_id}\",\"agent_id\":\"${agent_id}\",\"dispatched_at\":\"${dispatched_ts}\",\"elapsed_s\":${elapsed_s}"
        stall_count=$(( stall_count + 1 ))

    done < "$AMBIENT"

    _log "Trigger 3 done: stalls_detected=$stall_count"
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "1" ]]; then
    _log "DRY_RUN mode active — no pushes will occur"
fi

[[ "$RUN_TRIGGER1" -eq 1 ]] && _trigger1_orphan_events
[[ "$RUN_TRIGGER2" -eq 1 ]] && _trigger2_branch_scan
[[ "$RUN_TRIGGER3" -eq 1 ]] && _trigger3_stall_detection

_log "last-mile-rescuer tick complete"
