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
#   ./scripts/ops/stale-worktree-reaper.sh              # default: --dry-run
#   ./scripts/ops/stale-worktree-reaper.sh --dry-run    # explicit dry-run
#   ./scripts/ops/stale-worktree-reaper.sh --execute    # actually reap
#   ./scripts/ops/stale-worktree-reaper.sh --execute --age-min 3
#   ./scripts/ops/stale-worktree-reaper.sh --log-fresh-min 30      # require 30min log quiet
#   ./scripts/ops/stale-worktree-reaper.sh --force-skip-process-check  # EMERGENCY override
#
# Cron (launchd):
#   ~/Library/LaunchAgents/dev.chump.stale-worktree-reaper.plist
#   wraps `bash -lc "$REPO/scripts/ops/stale-worktree-reaper.sh --execute"` with
#   StartInterval 3600. See scripts/setup/install-stale-worktree-reaper-launchd.sh.
#
# Disable temporarily:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.stale-worktree-reaper.plist
#
# Bypass per-worktree:
#   touch <worktree-path>/.chump-no-reap   # respected by this script

set -euo pipefail

# INFRA-120: shared instrumentation (heartbeat + ambient reaper_run event +
# log rotation). Watchdog reads /tmp/chump-reaper-worktree.heartbeat.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup worktree
reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free
reaper_rotate_log /tmp/chump-stale-worktree-reaper.out.log
reaper_rotate_log /tmp/chump-stale-worktree-reaper.err.log
reaper_rotate_log /tmp/stale-worktree-reaper.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

# ---- arg parsing ----
DRY_RUN=1
AGE_MIN_HOURS=1
LOG_FRESH_MIN=10
FORCE_SKIP_PROCESS_CHECK=0
# INFRA-1074: CHUMP_REAPER_SAFETY_CHECK=0 disables heartbeat+index safety checks
# (for testing the reaper itself without tripping the guards).
REAPER_SAFETY_CHECK="${CHUMP_REAPER_SAFETY_CHECK:-1}"
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname || true)"
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

# INFRA-1074: emit kind=worktree_reaper_skipped_active to ambient.jsonl
_emit_reaper_skipped() {
    local wt_path="$1" reason="$2"
    local ambient="${CHUMP_AMBIENT_LOG:-$LOCKS_DIR/ambient.jsonl}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"worktree_reaper_skipped_active","worktree":"%s","reason":"%s"}\n' \
        "$ts" "$wt_path" "$reason" >> "$ambient" 2>/dev/null || true
    log "SKIP_ACTIVE $wt_path reason=$reason"
}

# INFRA-1291: emit kind=worktree_reap_protected when a stale-looking worktree
# was spared because its lease heartbeat_at is within CHUMP_LEASE_HEARTBEAT_TTL_S.
# Distinct from worktree_reaper_skipped_active (which covers all active-lease skips);
# this event signals the specific heartbeat-freshness protection path.
_emit_worktree_reap_protected() {
    local wt_path="$1" lease="$2"
    local ambient="${CHUMP_AMBIENT_LOG:-$LOCKS_DIR/ambient.jsonl}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"worktree_reap_protected","worktree":"%s","lease":"%s","ttl_s":%d}\n' \
        "$ts" "$wt_path" "$(basename "$lease")" "${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}" \
        >> "$ambient" 2>/dev/null || true
    log "REAP_PROTECTED $wt_path via fresh heartbeat in $lease"
}

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
# INFRA-1053: harness-agnostic base. Default keeps .claude/worktrees/.
_REAPER_WT_BASE="${CHUMP_WORKTREE_BASE:-$REPO_ROOT/.claude/worktrees}"
for wt in "$_REAPER_WT_BASE"/*/; do
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
# INFRA-1074: only count leases with heartbeat_at within last 15 min (900s).
# INFRA-1212: lease parsing moved to scripts/lib/lease.sh (single canonical
# reader for all 8 reaper / scanner / driver scripts). Behavior unchanged:
# 15-min freshness threshold per INFRA-1074, fallback chain heartbeat_at >
# taken_at, grep fallback when jq absent — all handled by the lib.
# shellcheck source=../lib/lease.sh
source "$REPO_ROOT/scripts/lib/lease.sh"

ACTIVE_WORKTREES=""
if [[ -d "$LOCKS_DIR" && "${REAPER_SAFETY_CHECK}" == "1" ]]; then
    while IFS= read -r lease; do
        [[ -f "$lease" ]] || continue
        wt="$(lease_worktree "$lease")"
        [[ -z "$wt" ]] && continue
        # INFRA-1074: skip leases with heartbeat stale beyond TTL.
        # INFRA-1291: TTL now configurable via CHUMP_LEASE_HEARTBEAT_TTL_S (default 600s).
        if ! lease_is_fresh "$lease" "${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}"; then
            age_s="$(lease_heartbeat_age_s "$lease")"
            info "  lease $lease: worktree=$wt but heartbeat is ${age_s}s old (>15 min) — not treating as active"
            continue
        fi
        ACTIVE_WORKTREES="$ACTIVE_WORKTREES $wt"
    done < <(lease_iter --repo "$REPO_ROOT")
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

    # Only consider worktrees under the worktree-base (never the main repo).
    # INFRA-1053: the legacy .claude/worktrees/ check is preserved; additionally
    # accept anything under CHUMP_WORKTREE_BASE when configured.
    case "$wt_path" in
        */\.claude/worktrees/*) ;;
        *)
            if [[ -n "${CHUMP_WORKTREE_BASE:-}" && "$wt_path" == "${CHUMP_WORKTREE_BASE%/}/"* ]]; then
                :
            else
                return 0
            fi
            ;;
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
        # INFRA-1291: emit worktree_reap_protected (distinct from the generic
        # worktree_reaper_skipped_active) so observers can track heartbeat-TTL
        # protection specifically. Look up the protecting lease by scanning
        # .chump-locks/ (small set — ≤ active worker count).
        _protecting_lease=""
        while IFS= read -r _pl; do
            [[ -f "$_pl" ]] || continue
            _pl_wt="$(lease_worktree "$_pl")"
            [[ -z "$_pl_wt" ]] && continue
            if [[ "$_pl_wt" == "$wt_path" || "$(basename "$_pl_wt")" == "$wt_name" ]]; then
                _protecting_lease="$_pl"; break
            fi
        done < <(lease_iter --repo "$REPO_ROOT")
        _emit_worktree_reap_protected "$wt_path" "${_protecting_lease:-unknown}"
        _emit_reaper_skipped "$wt_path" "active_lease"
        KEPT=$((KEPT+1)); return 0
    fi

    # INFRA-1074: belt-and-suspenders — skip if .git/index was touched within 5 min.
    # Catches in-flight sessions whose lease has no worktree field (pre-fix leases)
    # or whose heartbeat expired but a commit is literally in progress.
    if [[ "${REAPER_SAFETY_CHECK}" == "1" ]]; then
        if [[ -f "$wt_path/.git" || -f "$wt_path/.git/index" ]]; then
            local git_index="$wt_path/.git/index"
            # For linked worktrees .git is a file pointing at the gitdir.
            if [[ -f "$wt_path/.git" ]]; then
                local gitdir; gitdir=$(sed 's/^gitdir: //' "$wt_path/.git" 2>/dev/null || true)
                [[ -n "$gitdir" && -f "$gitdir/index" ]] && git_index="$gitdir/index"
            fi
            if [[ -f "$git_index" ]]; then
                local idx_fresh
                idx_fresh=$(find "$git_index" -mmin -5 2>/dev/null | head -1 || true)
                if [[ -n "$idx_fresh" ]]; then
                    info "  .git/index touched within 5 min — worktree is in-flight, keeping"
                    _emit_reaper_skipped "$wt_path" "git_index_fresh"
                    KEPT=$((KEPT+1)); return 0
                fi
            fi
        fi
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

# INFRA-120: emit heartbeat + reaper_run event (counts include target/ purge).
trap - EXIT
reaper_finish ok "{\"reaped\":$REAPED,\"kept\":$KEPT,\"skipped\":$SKIPPED,\"target_purged\":${_target_purged:-0},\"target_freed_kb\":${_target_freed_kb:-0},\"dry_run\":$DRY_RUN}"

exit 0
