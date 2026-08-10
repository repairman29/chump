#!/usr/bin/env bash
# scripts/ops/checkout-sync.sh — MISSION-027
#
# Keeps the RUNNING checkout (the one the fleet's scripts/daemons/picker
# execute out of — scripts/dispatch/_pick_gap.py and friends) current with
# origin/main. MISSION-012's auto-deploy.sh only rebuilds the installed
# BINARY via an isolated /tmp worktree; it never touches this checkout's
# git state, so merged SCRIPT fixes (e.g. #3055, the picker fix) can sit
# inert for hours while the fleet keeps running stale code. This is the
# missing half of deploy.
#
# Logic:
#   (a) git fetch origin main                      — get latest remote state
#   (b) compare origin/main HEAD SHA to current HEAD
#   (c) if advanced:
#         - checkout HEAD's copy of known-disposable runtime paths so they
#           never block the fast-forward (they are regenerated state, not
#           config — see DISPOSABLE_PATHS below)
#         - stash any REMAINING dirty tracked changes (legit local edits)
#         - git merge --ff-only origin/main
#         - pop the stash back on top (best-effort; a real conflict leaves
#           the stash for manual recovery rather than silently discarding it)
#   (d) emit ambient kind=checkout_synced / checkout_sync_failed /
#       checkout_sync_dirty_tree_protected
#
# Never does a destructive reset/checkout of tracked files outside the
# disposable allowlist — legit local config is stashed, not discarded.
#
# Idempotent: exits 0 (no-op) when the checkout is already current.
#
# Environment overrides:
#   CHUMP_SYNC_TARGET_DIR   — checkout to sync (default: this script's repo root).
#                             Point this at the fleet's running checkout when
#                             invoking from elsewhere (dedicated fleet checkout).
#   CHUMP_SYNC_DISPOSABLE_PATHS — space-separated override of the disposable
#                             runtime-state allowlist (default set below)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_SYNC_TARGET_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
STATE_DIR="$REPO_ROOT/.chump-locks"
LOG_DIR="$STATE_DIR/checkout-sync-logs"
mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
LOG="$LOG_DIR/checkout-sync-$(date -u +%Y%m%dT%H%M%SZ).log"

# Disposable runtime state: regenerated continuously by the fleet, never
# hand-edited, safe to blow away on every sync. NOT config.
DEFAULT_DISPOSABLE_PATHS=".chump/github_cache.db .chump/state.db-wal .chump/state.db-shm"
DISPOSABLE_PATHS="${CHUMP_SYNC_DISPOSABLE_PATHS:-$DEFAULT_DISPOSABLE_PATHS}"

# scanner-anchor: "kind":"checkout_synced"
# scanner-anchor: "kind":"checkout_sync_failed"
# scanner-anchor: "kind":"checkout_sync_dirty_tree_protected"
# scanner-anchor: "kind":"checkout_sync_skipped"
emit_ambient() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

cd "$REPO_ROOT" || { log "FATAL: cannot cd to $REPO_ROOT"; exit 1; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log "FATAL: $REPO_ROOT is not a git checkout"
    exit 1
fi

CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [[ "$CUR_BRANCH" != "main" ]]; then
    log "SKIP: current branch is '$CUR_BRANCH', not main — refusing to sync a feature branch"
    emit_ambient "checkout_sync_skipped" "\"reason\":\"not_on_main\",\"branch\":\"$CUR_BRANCH\""
    exit 0
fi

# (a) Fetch latest main
if ! git fetch origin main --quiet 2>>"$LOG"; then
    log "WARN: git fetch failed (offline?); nothing to sync this cycle"
    emit_ambient "checkout_sync_skipped" "\"reason\":\"fetch_failed\""
    exit 0
fi

OLD_SHA="$(git rev-parse HEAD 2>/dev/null)"
MAIN_SHA="$(git rev-parse origin/main 2>/dev/null)"
OLD_SHA_SHORT="${OLD_SHA:0:12}"
MAIN_SHA_SHORT="${MAIN_SHA:0:12}"

if [[ "$OLD_SHA" == "$MAIN_SHA" ]]; then
    log "SKIP: checkout already current with origin/main (sha=$MAIN_SHA_SHORT)"
    emit_ambient "checkout_sync_skipped" "\"reason\":\"already_current\",\"sha\":\"$MAIN_SHA_SHORT\""
    ls -t "$LOG_DIR"/checkout-sync-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true
    exit 0
fi

log "SYNC: origin/main advanced (checkout=$OLD_SHA_SHORT, origin/main=$MAIN_SHA_SHORT)"

# (c-i) Reset known-disposable runtime state to HEAD's copy so it never
# blocks the fast-forward. Only touches paths in the allowlist.
for p in $DISPOSABLE_PATHS; do
    if [[ -e "$p" ]] && ! git diff --quiet -- "$p" 2>/dev/null; then
        git checkout -- "$p" 2>>"$LOG" || rm -f "$p" 2>/dev/null || true
        log "reset disposable runtime path: $p"
    fi
done

# (c-ii) Stash any remaining dirty TRACKED state (legit local edits) — never
# discard it outright. Deliberately no `-u`: untracked files (including our
# own .chump-locks/ log dir) never block `git merge --ff-only`, and stashing
# them would yank .chump-locks out from under this very script mid-run.
STASHED=0
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    STASH_MSG="checkout-sync-autostash-$(date -u +%Y%m%dT%H%M%SZ)"
    if git stash push -m "$STASH_MSG" >>"$LOG" 2>&1; then
        STASHED=1
        log "stashed legit local edits: $STASH_MSG"
        emit_ambient "checkout_sync_dirty_tree_protected" "\"stash_msg\":\"$STASH_MSG\""
    else
        log "FAIL: git stash push failed while dirty — aborting sync to avoid data loss"
        emit_ambient "checkout_sync_failed" "\"reason\":\"stash_failed\",\"main_sha\":\"$MAIN_SHA_SHORT\""
        exit 1
    fi
fi

# (c-iii) Fast-forward only. Never a merge commit, never a rebase — if this
# isn't a clean fast-forward something is structurally wrong (diverged
# history on main) and we bail loudly rather than force it.
if git merge --ff-only origin/main >>"$LOG" 2>&1; then
    NEW_SHA="$(git rev-parse HEAD)"
    NEW_SHA_SHORT="${NEW_SHA:0:12}"
    log "OK: fast-forwarded $OLD_SHA_SHORT -> $NEW_SHA_SHORT"

    POP_OK=1
    if [[ "$STASHED" -eq 1 ]]; then
        if git stash pop >>"$LOG" 2>&1; then
            log "restored stashed local edits"
        else
            POP_OK=0
            log "WARN: stash pop conflicted after ff — local edits left in stash for manual recovery (git stash list)"
        fi
    fi

    emit_ambient "checkout_synced" \
        "\"old_sha\":\"$OLD_SHA_SHORT\",\"new_sha\":\"$NEW_SHA_SHORT\",\"stash_pop_ok\":$( [[ $POP_OK -eq 1 ]] && echo true || echo false )"
else
    log "FAIL: fast-forward merge failed (diverged history?) — checkout left at $OLD_SHA_SHORT"
    if [[ "$STASHED" -eq 1 ]]; then
        git stash pop >>"$LOG" 2>&1 || log "WARN: stash pop also failed — local edits left in stash"
    fi
    emit_ambient "checkout_sync_failed" "\"reason\":\"ff_only_failed\",\"checkout_sha\":\"$OLD_SHA_SHORT\",\"main_sha\":\"$MAIN_SHA_SHORT\""
    exit 1
fi

ls -t "$LOG_DIR"/checkout-sync-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true

exit 0
