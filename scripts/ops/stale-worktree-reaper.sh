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
# What it does (per worktree under .claude/worktrees/ and /tmp/chump-*):
#   1. Find its branch.
#   2. Mark REAPABLE if EITHER:
#        - the branch's tip is an ancestor of origin/main (squash-merged or
#          fast-forwarded — work is on main), OR
#        - origin has no ref for the branch any more (PR closed/merged and
#          GitHub auto-deleted the head branch).
#      For /tmp/chump-<gap-id>/ worktrees, ALSO reapable if:
#        - The gap extracted from dirname has status=done in state.db, OR
#        - The matching PR is MERGED or CLOSED (checked via GitHub cache).
#   3. SKIP if any of:
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
#      then `git worktree remove --force <path>` (for git-linked worktrees)
#      or `rm -rf <path>` (for bare /tmp/chump-* directories not git-linked).
#
# Scan paths (INFRA-2020):
#   Default: WORKTREE_SCAN_PATHS=".claude/worktrees /tmp/chump-*"
#   Override via env: WORKTREE_SCAN_PATHS="/custom/path /other/path-*"
#   The git-worktree walk (via `git worktree list --porcelain`) still handles
#   .claude/worktrees/ (which are proper git linked worktrees). The /tmp/chump-*
#   pass handles the chump claim convention worktrees directly.
#
# INFRA-2339: Broadened scan — two new discovery paths beyond /tmp/chump-*:
#   1. ANY git-registered worktree whose path starts with /tmp/ is now included
#      via the git-worktree-list walk (scan_source=git-list). Catches orphans
#      like /tmp/infra-2446-fix (7.8 Gi) and /tmp/ship-068 (6.3 Gi) that were
#      invisible to the old /tmp/chump-* glob filter.
#   2. Standalone (non-git-registered) /tmp/ directories older than 12h that
#      match common rescue patterns (infra-NNNN-*, ship-NNN, fix-*, *-rescue,
#      *-fix) are enumerated by enumerate_tmp_rescue_orphans() and flagged
#      (scan_source=rescue-pattern or scan_source=tmp-age).
#   The existing SKIP heuristics (lsof, log-freshness, lease, age) are unchanged.
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
#
# INFRA-2020: /tmp/chump-* support (disk_critical source — 43GB recovered manually)
#   WORKTREE_SCAN_PATHS env var controls which directories are walked.
#   Default includes both .claude/worktrees and /tmp/chump-* to cover the
#   chump claim convention (creates /tmp/chump-<gap-id>/ directories).

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
# INFRA-2020: scan paths — default covers both .claude/worktrees (git linked worktrees)
# and /tmp/chump-* (chump claim convention). Override via WORKTREE_SCAN_PATHS env var.
# The /tmp/chump-* glob is intentional: claim creates /tmp/chump-<gap-id>/ directories.
WORKTREE_SCAN_PATHS="${WORKTREE_SCAN_PATHS:-.claude/worktrees /tmp/chump-*}"

# Resolve the main repo root (this script may be invoked from a worktree).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Allow tests to inject CHUMP_REPO_ROOT_OVERRIDE to redirect the reaper to a
# synthetic repo without touching SCRIPT_DIR (RESILIENT-029).
if [[ -n "${CHUMP_REPO_ROOT_OVERRIDE:-}" && -d "$CHUMP_REPO_ROOT_OVERRIDE" ]]; then
    REPO_ROOT="$CHUMP_REPO_ROOT_OVERRIDE"
else
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null \
        | xargs -I{} dirname {} 2>/dev/null || true)"
    # common-dir returns .git or path/.git; the repo root is its parent (when
    # basename = .git) or itself (when bare). Easier: ask the toplevel of the
    # common-dir's parent.
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname || true)"
    if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
        REPO_ROOT="/Users/jeffadkins/Projects/Chump"
    fi
fi

LOG=/tmp/stale-worktree-reaper.log
LOCKS_DIR="$REPO_ROOT/.chump-locks"
ARCHIVE_DIR="$REPO_ROOT/docs/archive/eval-runs"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
log()   { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >>"$LOG"; }

# INFRA-1211: _emit_reaper_skipped and _emit_worktree_reap_protected are now
# thin wrappers around emit_reaper_event() from scripts/lib/worktree-iter.sh.
# Kept as wrappers (not deleted) so callers deep in this file need no rewrite.
_emit_reaper_skipped() {
    local wt_path="$1" reason="$2"
    emit_reaper_event "worktree_reaper_skipped_active" "$wt_path" "$reason"
    log "SKIP_ACTIVE $wt_path reason=$reason"
}
_emit_worktree_reap_protected() {
    local wt_path="$1" lease="$2"
    emit_reaper_event "worktree_reap_protected" "$wt_path" \
        "active_lease_heartbeat_fresh" \
        "\"lease\":\"$(basename "$lease")\",\"ttl_s\":${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}"
    log "REAP_PROTECTED $wt_path via fresh heartbeat in $lease"
}

green "=== stale-worktree-reaper (repo: $REPO_ROOT) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no worktrees will be removed. Use --execute to act."
info "Age threshold: $AGE_MIN_HOURS hour(s) since branch merged."
info "Log-fresh window: $LOG_FRESH_MIN minute(s) (any logs/ mtime newer than this skips the worktree)."
[[ $FORCE_SKIP_PROCESS_CHECK -eq 1 ]] && warn "  --force-skip-process-check ACTIVE — lsof + log-mtime guards DISABLED"

cd "$REPO_ROOT"
git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    if git rev-parse --verify "$REMOTE/$BASE" >/dev/null 2>&1; then
        warn "Could not fetch $REMOTE/$BASE — using cached local ref (offline mode)"
        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"reaper_fetch_fallback","gap_id":null,"remote":"%s","base":"%s","reason":"offline"}\n' \
            "$_ts" "$REMOTE" "$BASE" >> "$REAPER_LOCK_DIR/ambient.jsonl"
    else
        red "Could not fetch $REMOTE/$BASE and no local ref — aborting."; exit 1
    fi
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
# INFRA-1211: shared worktree scanning + emission helpers.
# shellcheck source=scripts/lib/worktree-iter.sh
source "$REPO_ROOT/scripts/lib/worktree-iter.sh"
REAPER_NAME="${REAPER_NAME:-worktree}"
REAPER_REPO_ROOT="$REPO_ROOT"
export REAPER_REPO_ROOT

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

# RESILIENT-099: the loop above only sees .chump-locks/*.json leases, but interactive
# `chump claim` writes the lease to the state.db `leases` table ONLY (no JSON sidecar
# with a heartbeat). Without this, the reaper reaped an ACTIVELY-LEASED worktree
# (the auto-stash saved the work, but an active lease must HARD-BLOCK reap). Append
# every state.db lease whose claim has not expired so is_active_lease() protects it.
# Same canonical-store split as INFRA-2744 (bot-merge re-claim) / RESILIENT-103.
if [[ "${REAPER_SAFETY_CHECK}" == "1" ]] && command -v sqlite3 >/dev/null 2>&1; then
    _statedb="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
    if [[ -f "$_statedb" ]]; then
        _now_epoch="$(date -u +%s)"
        while IFS= read -r _wt; do
            [[ -n "$_wt" ]] && ACTIVE_WORKTREES="$ACTIVE_WORKTREES $_wt"
        done < <(sqlite3 "$_statedb" "SELECT worktree FROM leases WHERE worktree != '' AND expires_at > $_now_epoch;" 2>/dev/null || true)
    fi
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
    # INFRA-2020: optional source tag for ambient event differentiation.
    # Values: "claude_worktrees" (from .claude/worktrees/), "tmp_chump" (from /tmp/chump-*),
    #         "git-list" (any /tmp/* git-registered worktree — INFRA-2339),
    #         "rescue-pattern" (standalone /tmp/ dir matching rescue pattern — INFRA-2339),
    #         "tmp-age" (standalone /tmp/ dir matched by age — INFRA-2339).
    local wt_source="${3:-claude_worktrees}"
    [[ -z "$wt_path" ]] && return 0

    # Only consider worktrees under the worktree-base (never the main repo).
    # INFRA-1053: the legacy .claude/worktrees/ check is preserved; additionally
    # accept anything under CHUMP_WORKTREE_BASE when configured.
    # INFRA-2020: /tmp/chump-* paths bypass the base check — they're a separate
    # scan path handled by the tmp_chump pass below.
    # INFRA-2339: ANY /tmp/* path is now accepted when wt_source is git-list,
    # rescue-pattern, or tmp-age — these are enumerated by the new broad-scan
    # pass and must not be filtered out by the old chump-* name check.
    case "$wt_path" in
        */\.claude/worktrees/*) ;;
        /tmp/chump-*) ;;
        /tmp/*)
            # INFRA-2339: accept any /tmp/* when it comes from a broad-scan source.
            case "$wt_source" in
                git-list|rescue-pattern|tmp-age) ;;
                *)
                    if [[ -n "${CHUMP_WORKTREE_BASE:-}" && "$wt_path" == "${CHUMP_WORKTREE_BASE%/}/"* ]]; then
                        :
                    else
                        log "SKIP $wt_path reason=path_not_in_scan_scope source=$wt_source"
                        return 0
                    fi
                    ;;
            esac
            ;;
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

    # INFRA-2020: for /tmp/chump-<gap-id>/ worktrees, additionally check gap
    # status in state.db and PR merge state via GitHub cache.
    # INFRA-2339: also apply to git-list / rescue-pattern / tmp-age sources
    # whose dirname may encode a gap ID (e.g. /tmp/infra-2446-fix).
    if [[ $reapable -eq 0 ]] && [[ "$wt_source" == "tmp_chump" || "$wt_source" == "git-list" || "$wt_source" == "rescue-pattern" || "$wt_source" == "tmp-age" ]]; then
        local gap_id
        gap_id=$(basename "$wt_path" | sed 's/^chump-//' | tr '[:lower:]-' '[:upper:]-')
        if [[ -n "$gap_id" ]]; then
            # Check state.db for done status.
            local state_db="$REPO_ROOT/.chump/state.db"
            if [[ -f "$state_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
                local gap_status
                gap_status=$(sqlite3 "$state_db" \
                    "SELECT status FROM gaps WHERE id='$gap_id' LIMIT 1" 2>/dev/null || true)
                if [[ "$gap_status" == "done" ]]; then
                    reapable=1; reason="gap $gap_id status=done in state.db"
                fi
            fi
            # Check PR merge state via GitHub cache (INFRA-1081 cache-first reads).
            if [[ $reapable -eq 0 ]]; then
                local cache_db="$REPO_ROOT/.chump/github_cache.db"
                if [[ -f "$cache_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
                    local pr_state
                    pr_state=$(sqlite3 "$cache_db" \
                        "SELECT state FROM pr_state WHERE LOWER(title) LIKE LOWER('%$gap_id%') AND state IN ('MERGED','CLOSED') LIMIT 1" \
                        2>/dev/null || true)
                    if [[ -n "$pr_state" ]]; then
                        reapable=1; reason="gap $gap_id PR is $pr_state (cache)"
                    fi
                fi
            fi
        fi
    fi

    if [[ $reapable -eq 0 ]]; then
        info "  not reapable: branch ahead of $BASE and remote still exists — keeping"
        KEPT=$((KEPT+1)); return 0
    fi

    # Age check — when did the branch tip become reachable from main? Use
    # commit time on origin/main of the merge commit if any, else use the
    # branch's last commit time as a conservative proxy.
    # For /tmp/chump-* with no branch (detached or bare dir), fall back to
    # directory mtime as a conservative proxy.
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
    else
        # No branch info — use directory mtime as age proxy.
        # Applies to: tmp_chump (gap-status path), rescue-pattern, tmp-age orphans.
        local dir_mtime now age_hours
        dir_mtime=$(stat -f%m "$wt_path" 2>/dev/null || stat -c%Y "$wt_path" 2>/dev/null || echo 0)
        now=$(date +%s)
        age_hours=$(( (now - dir_mtime) / 3600 ))
        info "  age: $age_hours h since dir mtime (no branch — source=$wt_source)"
        if [[ $age_hours -lt $AGE_MIN_HOURS ]]; then
            info "  below age threshold ($AGE_MIN_HOURS h) — keeping for now"
            log "SKIP $wt_path reason=below_age_threshold age_h=$age_hours min_h=$AGE_MIN_HOURS scan_source=$wt_source"
            age_check_ok=0
        fi
    fi
    if [[ $age_check_ok -eq 0 ]]; then
        KEPT=$((KEPT+1)); return 0
    fi

    red "  REAPABLE: $reason"

    # RESILIENT-029: stash-and-push uncommitted/unpushed work to a wip/ branch
    # before reaping, so no work is silently destroyed.
    # This runs for ALL reapable worktrees — clean ones skip the push step.
    _wip_stash_work() {
        local wt="$1"
        # Only meaningful for git-linked worktrees (bare /tmp dirs have no git).
        [[ -f "$wt/.git" ]] || return 0

        local uncommitted=0 unpushed=0
        uncommitted=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        # Try @{u} first (requires tracking branch); fall back to origin/<branch>
        # so we catch unpushed commits even when the remote branch was deleted.
        if git -C "$wt" rev-parse '@{u}' >/dev/null 2>&1; then
            unpushed=$(git -C "$wt" log '@{u}..HEAD' --oneline 2>/dev/null | wc -l | tr -d ' ')
        else
            local _local_branch
            _local_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
            if [[ -n "$_local_branch" && "$_local_branch" != "HEAD" ]]; then
                # If origin/<branch> exists, count commits ahead of it.
                # If it was deleted (the reapable case), count commits ahead of origin/main
                # — those are local-only commits that must be preserved before reap.
                if git -C "$wt" rev-parse "origin/${_local_branch}" >/dev/null 2>&1; then
                    unpushed=$(git -C "$wt" log "origin/${_local_branch}..HEAD" --oneline 2>/dev/null \
                        | wc -l | tr -d ' \n')
                    unpushed="${unpushed:-0}"
                else
                    unpushed=$(git -C "$wt" log "origin/${BASE}..HEAD" --oneline 2>/dev/null \
                        | wc -l | tr -d ' \n')
                    unpushed="${unpushed:-0}"
                fi
            fi
        fi

        if [[ "$uncommitted" -eq 0 && "$unpushed" -eq 0 ]]; then
            return 0  # nothing to stash
        fi

        # Determine gap ID from claim file (best-effort).
        local claim_file gap_id ts wip_branch
        claim_file=$(ls "$LOCKS_DIR/claim-"*.json 2>/dev/null | head -1 || true)
        gap_id="unknown"
        if [[ -n "$claim_file" && -f "$claim_file" ]]; then
            if command -v jq >/dev/null 2>&1; then
                gap_id=$(jq -r '.gap_id // "unknown"' "$claim_file" 2>/dev/null || echo "unknown")
            else
                gap_id=$(grep -oE '"gap_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$claim_file" \
                    | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || echo "unknown")
            fi
        fi
        ts=$(date +%s)
        wip_branch="wip/$(echo "$gap_id" | tr '[:upper:]' '[:lower:]')-${ts}"

        info "  RESILIENT-029: worktree has uncommitted=$uncommitted / unpushed=$unpushed — stashing to $wip_branch"

        if [[ "$uncommitted" -gt 0 ]]; then
            git -C "$wt" add -A 2>/dev/null || true
            git -C "$wt" commit \
                -m "[stale-worktree-reaper auto-stash] uncommitted work at ${ts}" \
                --no-verify 2>/dev/null || true
        fi

        git -C "$wt" branch "$wip_branch" 2>/dev/null || true
        if git -C "$wt" push "$REMOTE" "$wip_branch" 2>/dev/null; then
            info "  pushed wip branch: $wip_branch"
            # scanner-anchor: "kind":"worktree_work_stashed_before_reap"
            printf '{"ts":"%s","kind":"worktree_work_stashed_before_reap","gap_id":"%s","branch":"%s","uncommitted_lines":%d,"unpushed_commits":%d,"original_worktree":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gap_id" "$wip_branch" \
                "$uncommitted" "$unpushed" "$wt" \
                >> "$LOCKS_DIR/ambient.jsonl" 2>/dev/null || true
            log "WIP_STASH $wt gap=$gap_id branch=$wip_branch uncommitted=$uncommitted unpushed=$unpushed"
        else
            warn "  push of $wip_branch failed — work may be lost; check $REMOTE connectivity"
            log "WIP_STASH_FAIL $wt gap=$gap_id branch=$wip_branch"
        fi
    }

    if [[ $DRY_RUN -eq 0 ]]; then
        _wip_stash_work "$wt_path"
    else
        # Dry-run: just report what would happen.
        local _dr_uncommitted _dr_unpushed
        _dr_uncommitted=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        _dr_unpushed=0
        if git -C "$wt_path" rev-parse @{u} >/dev/null 2>&1; then
            _dr_unpushed=$(git -C "$wt_path" log '@{u}..HEAD' --oneline 2>/dev/null | wc -l | tr -d ' ')
        fi
        if [[ "$_dr_uncommitted" -gt 0 || "$_dr_unpushed" -gt 0 ]]; then
            info "  [dry-run] would stash uncommitted=$_dr_uncommitted / unpushed=$_dr_unpushed to wip/<gap>-<ts>"
        fi
    fi

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
        case "$wt_source" in
            tmp_chump|rescue-pattern|tmp-age)
                info "  [dry-run] would: rm -rf $wt_path  [scan_source=$wt_source]"
                ;;
            git-list)
                info "  [dry-run] would: git worktree remove --force $wt_path  [scan_source=git-list]"
                ;;
            *)
                info "  [dry-run] would: git worktree remove --force $wt_path  [scan_source=$wt_source]"
                ;;
        esac
        log "DRY_RUN_REAPABLE $wt_path branch=$wt_branch reason='$reason' scan_source=$wt_source"
        # dry-run stash reporting already printed above in the _wip_stash_work block.
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

    # INFRA-2020: /tmp/chump-* directories may not be git-linked worktrees
    # (chump claim creates a bare dir then does git worktree add, but after
    # manual reaping or partial cleanup the git link may be gone). Try
    # git worktree remove first; fall back to rm -rf for bare dirs.
    local removed=0
    if [[ "$wt_source" == "tmp_chump" ]]; then
        if git worktree remove --force "$wt_path" 2>>"$LOG"; then
            removed=1
        elif rm -rf "$wt_path" 2>>"$LOG"; then
            removed=1
            log "REMOVED (rm -rf) $wt_path branch=$wt_branch reason='$reason'"
        fi
    else
        if git worktree remove --force "$wt_path" 2>>"$LOG"; then
            removed=1
        fi
    fi

    if [[ $removed -eq 1 ]]; then
        green "  REMOVED $wt_path  [scan_source=$wt_source]"
        log "REAPED $wt_path branch=$wt_branch reason='$reason' scan_source=$wt_source"
        # INFRA-2020: emit worktree_reaped with source= tag for audit differentiation.
        # INFRA-2339: add scan_source field distinguishing git-list / tmp-glob /
        #             rescue-pattern / tmp-age discovery paths.
        # scanner-anchor: "kind":"worktree_reaped"
        emit_reaper_event "worktree_reaped" "$wt_path" "$reason" \
            "\"source\":\"$wt_source\",\"scan_source\":\"$wt_source\",\"branch\":\"${wt_branch:-}\",\"dry_run\":0"
        REAPED=$((REAPED+1))
    else
        red "  FAILED to remove $wt_path  [scan_source=$wt_source]"
        log "REAP_FAIL $wt_path reason='$reason' scan_source=$wt_source"
        SKIPPED=$((SKIPPED+1))
    fi
}

# ── INFRA-2339: enumerate_tmp_rescue_orphans ──────────────────────────────────
# Finds standalone (non-git-registered) /tmp/ directories that match common
# rescue/work patterns and are older than ORPHAN_AGE_MIN_HOURS (default 12h).
# These are NOT surfaced by `git worktree list` and NOT matched by /tmp/chump-*.
# Patterns: infra-NNNN[-suffix], ship-NNN, fix-*, *-rescue, *-fix
#
# Emits one path per line to stdout. The caller tags each with scan_source.
ORPHAN_AGE_MIN_HOURS="${ORPHAN_AGE_MIN_HOURS:-12}"

# Build the set of all git-registered worktree paths so we can exclude them
# (they are already handled by the git-worktree-list pass).
_GIT_REGISTERED_PATHS=""
_RESCUE_SCAN_BASE="${CHUMP_RESCUE_SCAN_BASE:-/tmp}"
while IFS= read -r _gwl_line; do
    case "$_gwl_line" in
        worktree\ /tmp/*) _GIT_REGISTERED_PATHS="$_GIT_REGISTERED_PATHS ${_gwl_line#worktree }" ;;
    esac
    # Also collect paths under CHUMP_RESCUE_SCAN_BASE when overridden for testing
    # (case patterns don't expand variables, so use [[ == ]] prefix match instead).
    if [[ "$_RESCUE_SCAN_BASE" != "/tmp" && "$_gwl_line" == "worktree ${_RESCUE_SCAN_BASE}/"* ]]; then
        _GIT_REGISTERED_PATHS="$_GIT_REGISTERED_PATHS ${_gwl_line#worktree }"
    fi
done <<< "$WTLIST"

enumerate_tmp_rescue_orphans() {
    local min_age_h="${1:-$ORPHAN_AGE_MIN_HOURS}"
    local now; now=$(date +%s)
    local min_age_s=$(( min_age_h * 3600 ))
    # CHUMP_RESCUE_SCAN_BASE overrides /tmp for testing (CI can't use real /tmp).
    local _scan_base="${CHUMP_RESCUE_SCAN_BASE:-/tmp}"

    for _d in "$_scan_base"/*/; do
        _d="${_d%/}"
        [[ -d "$_d" ]] || continue

        local _name; _name=$(basename "$_d")

        # Skip main repo root (unlikely in /tmp but be safe).
        [[ "$_d" == "$REPO_ROOT" ]] && continue

        # Skip if already git-registered (handled by the git-worktree-list pass).
        case " $_GIT_REGISTERED_PATHS " in
            *" $_d "*) continue ;;
        esac

        # Skip if it looks like a chump-claim worktree (handled by tmp_chump pass).
        case "$_name" in
            chump-*) continue ;;
        esac

        # Pattern match — rescue/work naming conventions.
        local _matched=0
        case "$_name" in
            infra-[0-9]*|INFRA-[0-9]*)        _matched=1 ;;
            ship-[0-9]*)                        _matched=1 ;;
            fix-*)                              _matched=1 ;;
            *-rescue)                           _matched=1 ;;
            *-fix)                              _matched=1 ;;
        esac

        if [[ $_matched -eq 0 ]]; then
            continue
        fi

        # Age check — only flag dirs older than min_age_h.
        local _mtime
        _mtime=$(stat -f%m "$_d" 2>/dev/null || stat -c%Y "$_d" 2>/dev/null || echo 0)
        local _age_s=$(( now - _mtime ))
        if [[ $_age_s -lt $min_age_s ]]; then
            log "SKIP_ORPHAN $_d reason=too_young age_s=$_age_s min_age_s=$min_age_s"
            continue
        fi

        printf '%s\n' "$_d"
    done
}

# Stream the porcelain output, fire on blank line.
# INFRA-2339: tag any /tmp/* git-registered worktree with scan_source=git-list
# so process_worktree accepts it regardless of name pattern.
while IFS= read -r line; do
    if [[ -z "$line" ]]; then
        # Determine source: /tmp/* non-chump paths get git-list tag.
        _src="claude_worktrees"
        case "$current_path" in
            /tmp/chump-*) _src="tmp_chump" ;;
            /tmp/*)       _src="git-list" ;;
        esac
        process_worktree "$current_path" "$current_branch" "$_src"
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
_final_src="claude_worktrees"
case "$current_path" in
    /tmp/chump-*) _final_src="tmp_chump" ;;
    /tmp/*)       _final_src="git-list" ;;
esac
process_worktree "$current_path" "$current_branch" "$_final_src"

# ── INFRA-2020: /tmp/chump-* scan pass ───────────────────────────────────────
# The git worktree list walk above only sees git-linked worktrees. The chump
# claim convention creates /tmp/chump-<gap-id>/ directories which may become
# stale if the gap ships and the worktree is never cleaned up.
# This pass walks WORKTREE_SCAN_PATHS for non-.claude entries, expanding globs.
info "----"
info "INFRA-2020: /tmp/chump-* scan pass (WORKTREE_SCAN_PATHS='$WORKTREE_SCAN_PATHS')"
_TMP_REAPED=0
_TMP_KEPT=0
_TMP_SKIPPED=0

for _scan_pattern in $WORKTREE_SCAN_PATHS; do
    # Skip the .claude/worktrees path — already handled by git worktree list above.
    case "$_scan_pattern" in
        *\.claude/worktrees*) continue ;;
        *\.claude/worktrees)  continue ;;
    esac

    # Expand glob pattern; skip if nothing matches.
    for _wt in $_scan_pattern/; do
        # Remove trailing slash for path checks.
        _wt="${_wt%/}"
        [[ -d "$_wt" ]] || continue

        info "----"
        info "tmp_chump candidate: $_wt"

        # Skip if this is the main repo root itself.
        if [[ "$_wt" == "$REPO_ROOT" ]]; then
            info "  is repo root — skipping"
            continue
        fi

        # Determine if this is a git-linked worktree to find its branch.
        _tmp_branch=""
        if [[ -f "$_wt/.git" ]]; then
            _tmp_branch=$(git -C "$_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
            [[ "$_tmp_branch" == "HEAD" ]] && _tmp_branch=""
        fi

        # Call shared process_worktree with source=tmp_chump.
        _before_reaped=$REAPED
        _before_kept=$KEPT
        _before_skipped=$SKIPPED
        process_worktree "$_wt" "$_tmp_branch" "tmp_chump"
        _TMP_REAPED=$(( _TMP_REAPED + REAPED - _before_reaped ))
        _TMP_KEPT=$(( _TMP_KEPT + KEPT - _before_kept ))
        _TMP_SKIPPED=$(( _TMP_SKIPPED + SKIPPED - _before_skipped ))
    done
done
info "tmp_chump scan: $_TMP_REAPED reapable, $_TMP_KEPT kept, $_TMP_SKIPPED skipped"

# ── INFRA-2339: rescue-pattern orphan scan pass ───────────────────────────────
# Enumerate standalone /tmp/* dirs matching rescue naming patterns that are NOT
# git-registered worktrees (those are already covered by the git-list pass above).
# Root cause of 14 Gi orphan leak: /tmp/infra-2446-fix (7.8 Gi) and /tmp/ship-068
# (6.3 Gi) were not git-registered worktrees at reap time, and /tmp/chump-* glob
# only matched the chump claim convention.
info "----"
info "INFRA-2339: rescue-pattern orphan scan (ORPHAN_AGE_MIN_HOURS=$ORPHAN_AGE_MIN_HOURS)"
_RESCUE_REAPED=0
_RESCUE_KEPT=0
_RESCUE_SKIPPED=0

while IFS= read -r _rescue_wt; do
    [[ -d "$_rescue_wt" ]] || continue
    info "----"
    info "rescue-pattern candidate: $_rescue_wt"

    # Determine scan_source: dirs with a git worktree marker use rescue-pattern;
    # plain dirs (no .git file) still use rescue-pattern (git-list covered above).
    _rescue_src="rescue-pattern"

    _before_reaped=$REAPED
    _before_kept=$KEPT
    _before_skipped=$SKIPPED
    process_worktree "$_rescue_wt" "" "$_rescue_src"
    _RESCUE_REAPED=$(( _RESCUE_REAPED + REAPED - _before_reaped ))
    _RESCUE_KEPT=$(( _RESCUE_KEPT + KEPT - _before_kept ))
    _RESCUE_SKIPPED=$(( _RESCUE_SKIPPED + SKIPPED - _before_skipped ))
done < <(enumerate_tmp_rescue_orphans "$ORPHAN_AGE_MIN_HOURS")
info "rescue-pattern scan: $_RESCUE_REAPED reapable, $_RESCUE_KEPT kept, $_RESCUE_SKIPPED skipped"

echo ""
green "=== reaper done: ${REAPED} reapable, ${KEPT} kept, ${SKIPPED} skipped ==="
[[ $DRY_RUN -eq 1 ]] && info "Re-run with --execute to actually remove worktrees."

# INFRA-120: emit heartbeat + reaper_run event (counts include target/ purge).
trap - EXIT
reaper_finish ok "{\"reaped\":$REAPED,\"kept\":$KEPT,\"skipped\":$SKIPPED,\"target_purged\":${_target_purged:-0},\"target_freed_kb\":${_target_freed_kb:-0},\"dry_run\":$DRY_RUN}"

exit 0
