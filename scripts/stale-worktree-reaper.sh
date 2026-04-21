#!/usr/bin/env bash
# stale-worktree-reaper.sh — Auto-remove linked worktrees whose branches have
# already merged to main (or had their remote branch deleted).
#
# Cousin to stale-pr-reaper.sh. That one closes orphaned PRs; this one cleans
# up orphaned worktrees on disk. Sessions can pile up 5-10+ linked worktrees
# under .claude/worktrees/ over a single dogfood day. Most of them have already
# shipped their gap and are dead weight: they slow down `git worktree list`,
# clutter `git status` for sibling agents, and confuse new sessions about what
# work is in flight.
#
# What it does (per worktree under .claude/worktrees/):
#   1. Find its branch.
#   2. Mark REAPABLE if EITHER:
#        - the branch's tip is an ancestor of origin/main (squash-merged or
#          fast-forwarded — work is on main), OR
#        - origin has no ref for the branch any more (PR closed/merged and
#          GitHub auto-deleted the head branch).
#   3. SKIP if any of:
#        - worktree has uncommitted changes
#        - any active lease in .chump-locks/*.json names this worktree
#        - the merged-age is below --age-min hours (default 1h cooldown so
#          we don't reap a worktree the agent is still cleaning up)
#        - any process has cwd inside the worktree or has a file open under
#          it (lsof +D check) — prevents reaping while a background sweep
#          is still writing. (INFRA-WORKTREE-REAPER-FIX, EVAL-026c data loss)
#        - any file under <worktree>/logs/ has been modified within
#          --log-fresh-min minutes (default 10) — heuristic for live writers
#          that lsof might miss (e.g. burst writers between samples)
#   4. For each reapable worktree, archive logs/ab/*.summary.json and
#      logs/ab/*.jsonl into docs/archive/eval-runs/<branch>-YYYY-MM-DD/,
#      then `git worktree remove --force <path>`.
#
# Usage:
#   ./scripts/stale-worktree-reaper.sh              # default: --dry-run
#   ./scripts/stale-worktree-reaper.sh --dry-run    # explicit dry-run
#   ./scripts/stale-worktree-reaper.sh --execute    # actually reap
#   ./scripts/stale-worktree-reaper.sh --execute --age-min 3
#   ./scripts/stale-worktree-reaper.sh --log-fresh-min 30      # require 30min log quiet
#   ./scripts/stale-worktree-reaper.sh --force-skip-process-check  # EMERGENCY override
#
# Cron (launchd):
#   ~/Library/LaunchAgents/ai.openclaw.chump-stale-worktree-reaper.plist
#   wraps `bash -lc "$REPO/scripts/stale-worktree-reaper.sh --execute"` with
#   StartInterval 3600. See scripts/install-stale-worktree-reaper-launchd.sh.
#
# Disable temporarily:
#   launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-stale-worktree-reaper.plist
#
# Bypass per-worktree:
#   touch <worktree-path>/.chump-no-reap   # respected by this script

set -euo pipefail

# ---- arg parsing ----
DRY_RUN=1
AGE_MIN_HOURS=1
LOG_FRESH_MIN=10
FORCE_SKIP_PROCESS_CHECK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --execute)  DRY_RUN=0 ;;
        --age-min)  AGE_MIN_HOURS="$2"; shift ;;
        --log-fresh-min)  LOG_FRESH_MIN="$2"; shift ;;
        --force-skip-process-check)  FORCE_SKIP_PROCESS_CHECK=1 ;;
        -h|--help)  sed -n '2,46p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"

# Resolve the main repo root (this script may be invoked from a worktree).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null \
    | xargs -I{} dirname {} 2>/dev/null || true)"
# common-dir returns .git or path/.git; the repo root is its parent (when
# basename = .git) or itself (when bare). Easier: ask the toplevel of the
# common-dir's parent.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname || true)"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
    REPO_ROOT="/Users/jeffadkins/Projects/Chump"
fi

LOG=/tmp/stale-worktree-reaper.log
LOCKS_DIR="$REPO_ROOT/.chump-locks"
ARCHIVE_DIR="$REPO_ROOT/docs/archive/eval-runs"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
log()   { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >>"$LOG"; }

green "=== stale-worktree-reaper (repo: $REPO_ROOT) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no worktrees will be removed. Use --execute to act."
info "Age threshold: $AGE_MIN_HOURS hour(s) since branch merged."
info "Log-fresh window: $LOG_FRESH_MIN minute(s) (any logs/ mtime newer than this skips the worktree)."
[[ $FORCE_SKIP_PROCESS_CHECK -eq 1 ]] && warn "  --force-skip-process-check ACTIVE — lsof + log-mtime guards DISABLED"

cd "$REPO_ROOT"
git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    red "Could not fetch $REMOTE/$BASE — aborting."; exit 1
}

# ── INFRA-017: target/ purge pass (independent of worktree removal) ──────────
# Frozen worktrees (.bot-merge-shipped present) keep a full Rust target/ each
# (1.4–9 GB). With ~25 frozen worktrees the 460 GB disk fills to 100%, breaking
# subsequent bot-merge.sh at clippy with "No space left on device". bot-merge.sh
# now purges target/ at ship time, but this sweep handles pre-existing frozen
# worktrees plus any that slipped past (e.g. CHUMP_KEEP_TARGET=1 forgotten).
# A shipped worktree will never rebuild — no further clippy/test runs happen
# there — so the cache is dead weight. Runs before the reap loop so even
# worktrees that aren't yet reapable (PR still in merge queue) reclaim disk.
info "----"
info "target/ purge pass (frozen worktrees only)…"
_target_purged=0
_target_freed_kb=0
for wt in "$REPO_ROOT"/.claude/worktrees/*/; do
    [[ -d "$wt" ]] || continue
    [[ -f "$wt/.bot-merge-shipped" ]] || continue
    [[ -d "$wt/target" ]] || continue
    _size_kb=$(du -sk "$wt/target" 2>/dev/null | awk '{print $1}')
    _size_kb="${_size_kb:-0}"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "  [dry-run] would purge ${wt}target (${_size_kb} KB)"
    else
        rm -rf "$wt/target" && info "  purged ${wt}target (${_size_kb} KB)"
        log "PURGE target/ $wt (${_size_kb} KB)"
    fi
    _target_purged=$((_target_purged + 1))
    _target_freed_kb=$((_target_freed_kb + _size_kb))
done
info "target/ purge: $_target_purged dir(s), $((_target_freed_kb / 1024)) MB $([[ $DRY_RUN -eq 1 ]] && echo 'would be freed' || echo 'freed')"

# Collect active-lease worktree paths (so we never reap a worktree that an
# active session is currently using). Lease JSON has a "worktree" field; we
# also fall back to substring match on the lease filename.
ACTIVE_WORKTREES=""
if [[ -d "$LOCKS_DIR" ]]; then
    for lease in "$LOCKS_DIR"/*.json; do
        [[ -f "$lease" ]] || continue
        # Try jq first; fall back to grep.
        wt=""
        if command -v jq >/dev/null 2>&1; then
            wt=$(jq -r '.worktree // empty' "$lease" 2>/dev/null || true)
        fi
        [[ -z "$wt" ]] && wt=$(grep -oE '"worktree"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" \
            | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        [[ -n "$wt" ]] && ACTIVE_WORKTREES="$ACTIVE_WORKTREES $wt"
    done
fi

is_active_lease() {
    # $1 = worktree basename
    local wt="$1"
    for a in $ACTIVE_WORKTREES; do
        [[ "$a" == "$wt" ]] && return 0
        # Also match on full path suffix.
        [[ "$a" == */"$wt" ]] && return 0
    done
    return 1
}

REAPED=0
SKIPPED=0
KEPT=0

# `git worktree list --porcelain` emits per-worktree blocks separated by blanks.
# Fields we care about: worktree <path>, branch refs/heads/<name>.
WTLIST=$(git worktree list --porcelain)

current_path=""
current_branch=""

process_worktree() {
    local wt_path="$1" wt_branch="$2"
    [[ -z "$wt_path" ]] && return 0

    # Only consider worktrees under .claude/worktrees/ (never the main repo).
    case "$wt_path" in
        */\.claude/worktrees/*) ;;
        *) return 0 ;;
    esac

    local wt_name; wt_name=$(basename "$wt_path")
    info "----"
    info "worktree: $wt_path  branch=$wt_branch"

    if [[ ! -d "$wt_path" ]]; then
        warn "  path missing — git worktree prune would clean this; skipping"
        SKIPPED=$((SKIPPED+1)); return 0
    fi

    if [[ -e "$wt_path/.chump-no-reap" ]]; then
        info "  .chump-no-reap sentinel present — skipping"
        SKIPPED=$((SKIPPED+1)); return 0
    fi

    # Uncommitted changes?
    if ! git -C "$wt_path" diff --quiet 2>/dev/null \
       || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
        info "  has uncommitted changes — keeping"
        KEPT=$((KEPT+1)); return 0
    fi
    # Untracked?
    if [[ -n "$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
        info "  has untracked files — keeping"
        KEPT=$((KEPT+1)); return 0
    fi

    if is_active_lease "$wt_name"; then
        info "  active lease references this worktree — keeping"
        KEPT=$((KEPT+1)); return 0
    fi

    # Process-aware safety check (INFRA-WORKTREE-REAPER-FIX, EVAL-026c).
    # Refuse to reap if any process has cwd in the worktree or has a file open
    # under it. lsof +D walks the dir; portable on macOS + Linux.
    if [[ $FORCE_SKIP_PROCESS_CHECK -eq 0 ]]; then
        if command -v lsof >/dev/null 2>&1; then
            local lsof_out
            lsof_out=$(lsof +D "$wt_path" 2>/dev/null | grep -v '^COMMAND' | head -5 || true)
            if [[ -n "$lsof_out" ]]; then
                info "  SKIP: active processes hold files in $wt_path (lsof match):"
                while IFS= read -r ln; do
                    [[ -n "$ln" ]] && info "    $ln"
                done <<<"$lsof_out"
                SKIPPED=$((SKIPPED+1)); return 0
            fi
        fi

        # Log-mtime safety: any file in logs/ touched within $LOG_FRESH_MIN
        # minutes is a strong signal a writer is active even if lsof missed
        # them (e.g. burst writers between sample windows).
        if [[ -d "$wt_path/logs" ]]; then
            local fresh_logs
            fresh_logs=$(find "$wt_path/logs" -type f -mmin -"$LOG_FRESH_MIN" 2>/dev/null | head -3 || true)
            if [[ -n "$fresh_logs" ]]; then
                info "  SKIP: logs/ files modified < $LOG_FRESH_MIN min ago in $wt_path:"
                while IFS= read -r ln; do
                    [[ -n "$ln" ]] && info "    $ln"
                done <<<"$fresh_logs"
                SKIPPED=$((SKIPPED+1)); return 0
            fi
        fi
    else
        info "  WARN: --force-skip-process-check active; lsof + log-mtime checks bypassed"
    fi

    # Reapability:
    local reapable=0 reason=""
    local remote_exists=0
    if [[ -n "$wt_branch" ]] && git ls-remote --heads "$REMOTE" "$wt_branch" 2>/dev/null | grep -q .; then
        remote_exists=1
    fi

    if [[ -n "$wt_branch" ]] && git merge-base --is-ancestor "$wt_branch" "$REMOTE/$BASE" 2>/dev/null; then
        reapable=1; reason="branch merged into $REMOTE/$BASE"
    elif [[ $remote_exists -eq 0 ]]; then
        reapable=1; reason="origin branch deleted"
    fi

    if [[ $reapable -eq 0 ]]; then
        info "  not reapable: branch ahead of $BASE and remote still exists — keeping"
        KEPT=$((KEPT+1)); return 0
    fi

    # Age check — when did the branch tip become reachable from main? Use
    # commit time on origin/main of the merge commit if any, else use the
    # branch's last commit time as a conservative proxy.
    local age_check_ok=1
    if [[ -n "$wt_branch" ]]; then
        local tip_ts
        tip_ts=$(git -C "$wt_path" log -1 --format=%ct 2>/dev/null || echo 0)
        local now; now=$(date +%s)
        local age_hours=$(( (now - tip_ts) / 3600 ))
        info "  age: $age_hours h since last commit on branch"
        if [[ $age_hours -lt $AGE_MIN_HOURS ]]; then
            info "  below age threshold ($AGE_MIN_HOURS h) — keeping for now"
            age_check_ok=0
        fi
    fi
    if [[ $age_check_ok -eq 0 ]]; then
        KEPT=$((KEPT+1)); return 0
    fi

    red "  REAPABLE: $reason"

    # Archive logs/ab artifacts if any.
    local arch_dest="$ARCHIVE_DIR/${wt_branch:-$wt_name}-$(date +%Y-%m-%d)"
    arch_dest="${arch_dest//\//_}"
    arch_dest="$ARCHIVE_DIR/$(basename "$arch_dest")"
    local has_artifacts=0
    if compgen -G "$wt_path/logs/ab/*.summary.json" >/dev/null \
       || compgen -G "$wt_path/logs/ab/*.jsonl" >/dev/null; then
        has_artifacts=1
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "  [dry-run] would archive logs/ab/* → $arch_dest"
        info "  [dry-run] would: git worktree remove --force $wt_path"
        REAPED=$((REAPED+1))
        return 0
    fi

    if [[ $has_artifacts -eq 1 ]]; then
        mkdir -p "$arch_dest"
        cp -p "$wt_path/logs/ab/"*.summary.json "$arch_dest/" 2>/dev/null || true
        cp -p "$wt_path/logs/ab/"*.jsonl "$arch_dest/" 2>/dev/null || true
        info "  archived → $arch_dest"
        log "ARCHIVE $wt_path -> $arch_dest"
    fi

    if git worktree remove --force "$wt_path" 2>>"$LOG"; then
        green "  REMOVED $wt_path"
        log "REMOVED $wt_path branch=$wt_branch reason='$reason'"
        REAPED=$((REAPED+1))
    else
        red "  FAILED to remove $wt_path (see $LOG)"
        SKIPPED=$((SKIPPED+1))
    fi
}

# Stream the porcelain output, fire on blank line.
while IFS= read -r line; do
    if [[ -z "$line" ]]; then
        process_worktree "$current_path" "$current_branch"
        current_path=""; current_branch=""
        continue
    fi
    case "$line" in
        worktree\ *) current_path="${line#worktree }" ;;
        branch\ *)   current_branch="${line#branch refs/heads/}" ;;
        detached)    current_branch="" ;;
    esac
done <<< "$WTLIST"
# Final block (no trailing blank).
process_worktree "$current_path" "$current_branch"

echo ""
green "=== reaper done: ${REAPED} reapable, ${KEPT} kept, ${SKIPPED} skipped ==="
[[ $DRY_RUN -eq 1 ]] && info "Re-run with --execute to actually remove worktrees."
exit 0
