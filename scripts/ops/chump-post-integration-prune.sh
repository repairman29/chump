#!/usr/bin/env bash
# chump-post-integration-prune.sh — INFRA-2138 (META-124/C10)
#
# Listens for integration_cycle_shipped ambient events and prunes per-gap
# branches on origin after a configurable grace window (default 24h).
#
# Behavior per event:
#   1. tail -F .chump-locks/ambient.jsonl | grep integration_cycle_shipped
#   2. Parse final_manifest.gap_ids → branch names (chump/<gap-id-lowercase>-claim)
#   3. Schedule prune at +GRACE via a background sleep loop
#   4. At prune time: verify integration PR still merged + not reverted
#   5. If safe: gh api -X DELETE /repos/<owner>/<repo>/git/refs/heads/<branch>
#   6. Emit ambient kind=per_gap_branch_pruned with {branch, gap_id, cycle_id}
#
# Idempotent: same event handled twice → noop on second pass (seen_events log).
#
# Configuration:
#   CHUMP_POST_INTEGRATION_PRUNE_GRACE_H=24   grace window in hours (default 24)
#   CHUMP_POST_INTEGRATION_PRUNE_DRY_RUN=1    log what would be pruned, no delete
#
# Usage:
#   bash scripts/ops/chump-post-integration-prune.sh          # run daemon (blocking)
#   bash scripts/ops/chump-post-integration-prune.sh --once   # process backlog once + exit
#
# Cross-references: INFRA-2130 (emits integration_cycle_shipped),
#                   INFRA-2131 (companion: integrator installer),
#                   INFRA-2125 (plist lesson)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"
STATE_DIR="${CHUMP_POST_INTEGRATION_PRUNE_STATE_DIR:-${HOME}/.chump/post-integration-prune}"
SEEN_FILE="${STATE_DIR}/seen-events.log"

GRACE_H="${CHUMP_POST_INTEGRATION_PRUNE_GRACE_H:-24}"
DRY_RUN="${CHUMP_POST_INTEGRATION_PRUNE_DRY_RUN:-0}"
ONCE_MODE=0

for _arg in "$@"; do
    [[ "$_arg" == "--once" ]] && ONCE_MODE=1
    [[ "$_arg" == "--dry-run" ]] && DRY_RUN=1
done

mkdir -p "$STATE_DIR"
touch "$SEEN_FILE"

# ── helpers ───────────────────────────────────────────────────────────────────

log() { printf '[post-integration-prune] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

emit_ambient() {
    local kind="$1" branch="$2" gap_id="$3" cycle_id="$4"
    printf '{"ts":"%s","kind":"%s","branch":"%s","gap_id":"%s","cycle_id":"%s","dry_run":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$kind" "$branch" "$gap_id" "$cycle_id" \
        "$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
        >> "$AMBIENT_LOG"
}

# Resolve owner/repo from git remote
get_repo_slug() {
    git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
        | sed -E 's|.*github\.com[:/]||; s|\.git$||'
}

# Check if a branch still exists on origin
branch_exists_on_origin() {
    local branch="$1" repo="$2"
    gh api "repos/${repo}/git/refs/heads/${branch}" >/dev/null 2>&1
}

# Verify integration PR for a gap is still merged (not reverted).
# Returns 0 if safe to prune, 1 if integration PR was reverted or not found.
integration_pr_still_merged() {
    local gap_id="$1" repo="$2"
    # Look up the gap's shipped PR from state.db
    local pr_num
    pr_num="$(chump gap show "$gap_id" 2>/dev/null \
        | grep -oE 'closed_pr:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+' \
        | head -1 || echo "")"
    if [[ -z "$pr_num" ]]; then
        log "WARN: no closed_pr for $gap_id — skip prune (safe: branch stays)"
        return 1
    fi
    local state
    state="$(gh pr view "$pr_num" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")"
    if [[ "$state" == "MERGED" ]]; then
        return 0
    else
        log "WARN: PR #$pr_num for $gap_id is '$state' (not MERGED) — skip prune"
        return 1
    fi
}

prune_branch() {
    local branch="$1" gap_id="$2" cycle_id="$3" repo="$4"

    if ! branch_exists_on_origin "$branch" "$repo"; then
        log "INFO: branch $branch already gone — noop"
        emit_ambient "per_gap_branch_pruned" "$branch" "$gap_id" "$cycle_id"
        return 0
    fi

    if ! integration_pr_still_merged "$gap_id" "$repo"; then
        log "SKIP: $branch — integration PR not confirmed merged"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would DELETE refs/heads/$branch (gap=$gap_id cycle=$cycle_id)"
        emit_ambient "per_gap_branch_pruned" "$branch" "$gap_id" "$cycle_id"
        return 0
    fi

    log "DELETE: refs/heads/$branch (gap=$gap_id cycle=$cycle_id)"
    gh api -X DELETE "repos/${repo}/git/refs/heads/${branch}" 2>&1 \
        | { read -r msg || true; log "  gh response: ${msg:-ok}"; }
    emit_ambient "per_gap_branch_pruned" "$branch" "$gap_id" "$cycle_id"
    log "  pruned: $branch"
}

# Process a single integration_cycle_shipped JSON line
handle_event() {
    local line="$1"

    # Extract cycle_id (used for dedup)
    local cycle_id
    cycle_id="$(printf '%s' "$line" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('cycle_id',''))" 2>/dev/null || echo "")"

    if [[ -z "$cycle_id" ]]; then
        log "WARN: integration_cycle_shipped event missing cycle_id — skip"
        return 0
    fi

    # Idempotency: skip if already processed
    if grep -qF "$cycle_id" "$SEEN_FILE" 2>/dev/null; then
        log "INFO: cycle $cycle_id already processed — noop"
        return 0
    fi

    # Parse gap_ids from final_manifest
    local gap_ids_json
    gap_ids_json="$(printf '%s' "$line" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); fm=d.get('final_manifest',{}); \
         ids=fm.get('gap_ids',[]); print('\n'.join(ids))" 2>/dev/null || echo "")"

    if [[ -z "$gap_ids_json" ]]; then
        log "WARN: no gap_ids in final_manifest for cycle $cycle_id — skip"
        echo "$cycle_id" >> "$SEEN_FILE"
        return 0
    fi

    local repo
    repo="$(get_repo_slug)"
    if [[ -z "$repo" ]]; then
        log "ERROR: cannot determine repo slug from git remote — abort"
        return 1
    fi

    log "cycle $cycle_id: scheduling prune for gap_ids after ${GRACE_H}h grace"

    # Mark seen before spawning pruner (idempotent on crash+restart)
    echo "$cycle_id" >> "$SEEN_FILE"

    # In --once mode: prune synchronously so the caller can observe results.
    # In daemon mode: spawn background sleep so the event loop is not blocked.
    do_prune() {
        local _cycle_id="$1" _gap_ids_json="$2" _repo="$3"
        sleep_s=$(( GRACE_H * 3600 ))
        if [[ "$sleep_s" -gt 0 ]]; then
            log "sleeping ${GRACE_H}h (${sleep_s}s) before pruning cycle ${_cycle_id}"
            sleep "$sleep_s"
        fi
        log "grace window expired — pruning cycle ${_cycle_id}"
        while IFS= read -r gap_id; do
            [[ -z "$gap_id" ]] && continue
            branch="chump/$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')-claim"
            prune_branch "$branch" "$gap_id" "$_cycle_id" "$_repo"
        done <<< "$_gap_ids_json"
        log "cycle ${_cycle_id} prune complete"
    }

    if [[ "$ONCE_MODE" == "1" ]]; then
        do_prune "$cycle_id" "$gap_ids_json" "$repo"
    else
        do_prune "$cycle_id" "$gap_ids_json" "$repo" &
    fi
}

# ── main loop ────────────────────────────────────────────────────────────────

log "starting (grace=${GRACE_H}h dry_run=${DRY_RUN} once=${ONCE_MODE})"
log "watching: $AMBIENT_LOG"

if [[ "$ONCE_MODE" == "1" ]]; then
    # Process existing events in the log file once, then exit
    if [[ -f "$AMBIENT_LOG" ]]; then
        grep '"kind":"integration_cycle_shipped"' "$AMBIENT_LOG" 2>/dev/null \
            | while IFS= read -r line; do
                handle_event "$line"
              done || true
    fi
    # Wait for any background pruners spawned in --once mode
    wait
    log "once-mode complete — exiting"
    exit 0
fi

# Daemon mode: tail -F for new events
if [[ ! -f "$AMBIENT_LOG" ]]; then
    log "ambient log not found; creating: $AMBIENT_LOG"
    touch "$AMBIENT_LOG"
fi

tail -F "$AMBIENT_LOG" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *'"kind":"integration_cycle_shipped"'*)
            handle_event "$line" ;;
    esac
done
