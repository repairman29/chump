#!/usr/bin/env bash
# scripts/ops/node-script-host-refresh.sh — RESILIENT-1080
#
# WHY THIS EXISTS. A worker node runs its shell/script organs (worker.sh, the
# gap pickers _pick_gap.py / _pick_and_claim_gap.py, dispatch/*, bot-merge.sh)
# from a SCRIPT-HOST checkout — canonically ~/chump — that the worker cd's into
# each cycle and sources fresh. Merged fixes on origin/main only reach the
# running worker once that checkout advances. RESILIENT-200's node-refresh timer
# keeps the installed BINARY current but never touches the script-host checkout,
# and RESILIENT-491's node-main-sync.sh advances it with `git reset --hard` —
# which is UNSAFE on a live worker checkout: it silently discards node-local
# tracked customizations (e.g. the muscle-node organ-manifest.txt stopgap that
# declares this node's worker so organ-reconcile keeps it) and, run on a cadence,
# would re-clobber them every cycle. Precedent (mugman 2026-09-08): a checkout
# 13 commits behind main kept re-picking already-done gaps because the picker
# dedup fix (#4529) never reached it; the only durable cure is an organ that
# keeps the script-host current WITHOUT destroying node-local work.
#
# WHAT THIS DOES. Advance the script-host checkout to origin/main by
# FAST-FORWARD ONLY, preserving every node-local customization:
#
#   SAFETY CONTRACT
#   - Fast-forward only (`git merge --ff-only`). Never reset --hard, never
#     rebase, never move HEAD backward.
#   - Refuses to run on a linked worktree, or when HEAD is not `main` — it only
#     touches the main checkout's `main` ref, so no linked worktree (each on its
#     own chump/<gap> branch) is ever disturbed.
#   - Divergence guard: if HEAD carries local commits not on origin/main, STOP
#     with a loud signal and touch NOTHING.
#   - Node-local TRACKED modifications are stashed before the ff and re-applied
#     after (`git stash push` then `git stash pop`). On a pop CONFLICT the stash
#     is KEPT (recoverable) and the working tree is cleaned back to origin/main
#     with a loud signal — node-local work is never silently lost and the live
#     checkout is never left with conflict markers.
#   - UNTRACKED files (hand-deployed helpers, e.g. ~/node1-worker-run.sh copies)
#     are NEVER touched: no `-u` on stash, no `git clean`, ever.
#
# Idempotent + node-agnostic: resolves the repo from $CHUMP_SCRIPT_HOST_REPO,
# else the first of ~/chump / ~/Projects/Chump / ~/chump-host that is a git
# checkout, else walks up from this script. No hardcoded /root or /home/<user>.
#
# Usage: scripts/ops/node-script-host-refresh.sh   (one-shot; safe on a cadence)
#
# Env overrides:
#   CHUMP_SCRIPT_HOST_REPO   repo to refresh (default: see resolution above)
#   CHUMP_SCRIPT_HOST_AMBIENT ambient stream to append to (tests)
#   CHUMP_SCRIPT_HOST_LOGDIR  log dir override (tests)
#   CHUMP_SCRIPT_HOST_GIT_BIN override for `git` (tests: inject a failing stub)
#   CHUMP_SCRIPT_HOST_TARGET  ref to fast-forward to (default: origin/main)
#
# Emits (best-effort, appended to ambient):
#   node_script_host_noop           already at target — nothing to do
#   node_script_host_refreshed      fast-forwarded target reached, mods re-applied
#   node_script_host_fetch_failed   `git fetch` failed — aborted, nothing touched
#   node_script_host_diverged       local commits not on target — STOP, untouched
#   node_script_host_ff_failed      `git merge --ff-only` failed — aborted
#   node_script_host_mods_stashed   node-local tracked mods preserved in a stash
#   node_script_host_pop_conflict   stash re-apply conflicted — mods kept in stash
#   node_script_host_skipped_worktree  refused: linked worktree or HEAD != main
#
# Exit codes:
#   0  no-op (already fresh) or fast-forward succeeded (even if a pop conflict
#      left node-local mods parked in a stash — the code IS current)
#   1  fetch failed / ff failed / refused (worktree|not-main)
#   2  diverged (local commits) — operator/organ must reconcile

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_BIN="${CHUMP_SCRIPT_HOST_GIT_BIN:-git}"
TARGET_REF="${CHUMP_SCRIPT_HOST_TARGET:-origin/main}"

# ── resolve the script-host checkout ────────────────────────────────────────
resolve_repo() {
    if [[ -n "${CHUMP_SCRIPT_HOST_REPO:-}" ]]; then
        printf '%s\n' "$CHUMP_SCRIPT_HOST_REPO"; return 0
    fi
    local c
    for c in "$HOME/chump" "$HOME/Projects/Chump" "$HOME/chump-host"; do
        if [[ -e "$c/.git" ]]; then printf '%s\n' "$c"; return 0; fi
    done
    # walk up from this script as a last resort
    ( cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P )
}
REPO_ROOT="$(resolve_repo)"

AMBIENT="${CHUMP_SCRIPT_HOST_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LOG_DIR="${CHUMP_SCRIPT_HOST_LOGDIR:-$REPO_ROOT/.chump-locks/node-script-host-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run).log"

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}" ts line
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG" 2>/dev/null || true
}
log()     { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" 2>/dev/null; }
log_err() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2 2>/dev/null; }

git_c() { "$GIT_BIN" -C "$REPO_ROOT" "$@"; }

# scanner-anchor (RESILIENT-1080, docs/observability/EVENT_REGISTRY.yaml):
# scanner-anchor: "kind":"node_script_host_noop"
# scanner-anchor: "kind":"node_script_host_refreshed"
# scanner-anchor: "kind":"node_script_host_fetch_failed"
# scanner-anchor: "kind":"node_script_host_diverged"
# scanner-anchor: "kind":"node_script_host_ff_failed"
# scanner-anchor: "kind":"node_script_host_mods_stashed"
# scanner-anchor: "kind":"node_script_host_pop_conflict"
# scanner-anchor: "kind":"node_script_host_skipped_worktree"

[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || {
    # A linked worktree has a .git *file*, not a dir. Refuse either way: a
    # missing repo, or a linked worktree we must never advance.
    log_err "FATAL: '$REPO_ROOT' is not a main git checkout (no .git dir) — refusing"
    emit node_script_host_skipped_worktree "\"repo\":\"$REPO_ROOT\",\"reason\":\"not_main_checkout\""
    exit 1
}

# Only ever advance the main checkout's own `main` branch. A detached HEAD or a
# feature branch here is not ours to move.
CUR_BRANCH="$(git_c symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED")"
if [[ "$CUR_BRANCH" != "main" ]]; then
    log_err "FATAL: HEAD is '$CUR_BRANCH', not 'main' — refusing to touch script-host"
    emit node_script_host_skipped_worktree "\"repo\":\"$REPO_ROOT\",\"branch\":\"$CUR_BRANCH\",\"reason\":\"head_not_main\""
    exit 1
fi

cd "$REPO_ROOT" || { log_err "FATAL: cannot cd $REPO_ROOT"; exit 1; }
log "script-host refresh: repo=$REPO_ROOT target=$TARGET_REF"

LOCAL_SHA_BEFORE="$(git_c rev-parse HEAD 2>/dev/null || echo unknown)"

# ── fetch ───────────────────────────────────────────────────────────────────
FETCH_OUTPUT="$(git_c fetch origin main 2>&1)"; FETCH_RC=$?
printf '%s\n' "$FETCH_OUTPUT" >> "$LOG" 2>/dev/null || true
log "git fetch origin main exited $FETCH_RC"
if [[ "$FETCH_RC" -ne 0 ]]; then
    log_err "FATAL: git fetch failed (rc=$FETCH_RC) — aborting, nothing touched"
    FE="$(printf '%s' "$FETCH_OUTPUT" | head -c 400 | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')"
    emit node_script_host_fetch_failed "\"rc\":$FETCH_RC,\"output\":\"$FE\""
    exit 1
fi

TARGET_SHA="$(git_c rev-parse "$TARGET_REF" 2>/dev/null || echo "$LOCAL_SHA_BEFORE")"

# Already at (or ahead of / containing) the target → nothing to fast-forward.
if [[ "$LOCAL_SHA_BEFORE" == "$TARGET_SHA" ]] || git_c merge-base --is-ancestor "$TARGET_SHA" "$LOCAL_SHA_BEFORE" 2>/dev/null; then
    log "no-op: HEAD ($LOCAL_SHA_BEFORE) already contains target ($TARGET_SHA)"
    emit node_script_host_noop "\"sha\":\"$LOCAL_SHA_BEFORE\",\"target\":\"$TARGET_SHA\""
    exit 0
fi

# Divergence guard: HEAD must be an ANCESTOR of the target for a clean ff.
if ! git_c merge-base --is-ancestor "$LOCAL_SHA_BEFORE" "$TARGET_SHA" 2>/dev/null; then
    log_err "DIVERGED: HEAD ($LOCAL_SHA_BEFORE) has local commits not on $TARGET_REF ($TARGET_SHA) — STOP, nothing touched"
    emit node_script_host_diverged "\"head\":\"$LOCAL_SHA_BEFORE\",\"target\":\"$TARGET_SHA\""
    exit 2
fi

log "MAIN MOVED: $LOCAL_SHA_BEFORE -> $TARGET_SHA — preparing worktree-safe fast-forward"

# ── preserve node-local TRACKED modifications (untracked left in place) ──────
STASHED=0
if ! git_c diff --quiet 2>/dev/null || ! git_c diff --cached --quiet 2>/dev/null; then
    STASH_MSG="node-script-host-refresh $(date -u +%Y%m%dT%H%M%SZ)"
    if git_c stash push -m "$STASH_MSG" >>"$LOG" 2>&1; then
        STASHED=1
        log "stashed node-local tracked modifications ($STASH_MSG)"
        emit node_script_host_mods_stashed "\"msg\":\"$STASH_MSG\""
    else
        log_err "WARN: git stash push failed; aborting ff to avoid clobbering local mods"
        emit node_script_host_ff_failed "\"reason\":\"stash_push_failed\""
        exit 1
    fi
fi

# ── fast-forward ONLY ────────────────────────────────────────────────────────
FF_OUTPUT="$(git_c merge --ff-only "$TARGET_REF" 2>&1)"; FF_RC=$?
printf '%s\n' "$FF_OUTPUT" >> "$LOG" 2>/dev/null || true
log "git merge --ff-only $TARGET_REF exited $FF_RC"
if [[ "$FF_RC" -ne 0 ]]; then
    log_err "FATAL: fast-forward failed (rc=$FF_RC)"
    if [[ "$STASHED" -eq 1 ]]; then
        git_c stash pop >>"$LOG" 2>&1 || log_err "WARN: could not restore stash after ff failure — mods parked in stash"
    fi
    emit node_script_host_ff_failed "\"rc\":$FF_RC"
    exit 1
fi

# ── re-apply node-local mods ─────────────────────────────────────────────────
if [[ "$STASHED" -eq 1 ]]; then
    if git_c stash pop >>"$LOG" 2>&1; then
        log "re-applied node-local tracked modifications"
    else
        # Conflict: KEEP the stash (recoverable), clean the working tree back to
        # the fast-forwarded target (no conflict markers left live), and signal
        # loudly. The CODE is current; the node-local mods survive in the stash.
        log_err "WARN: stash pop conflicted — node-local mods KEPT in stash, working tree reset to $TARGET_SHA"
        git_c reset --hard HEAD >>"$LOG" 2>&1 || true
        emit node_script_host_pop_conflict "\"target\":\"$TARGET_SHA\",\"note\":\"node-local mods preserved in git stash list\""
    fi
fi

LOCAL_SHA_AFTER="$(git_c rev-parse HEAD 2>/dev/null || echo unknown)"
log "refreshed: HEAD now $LOCAL_SHA_AFTER"
emit node_script_host_refreshed "\"from\":\"$LOCAL_SHA_BEFORE\",\"to\":\"$LOCAL_SHA_AFTER\""
exit 0
