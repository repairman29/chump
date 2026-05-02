#!/usr/bin/env bash
# worker.sh — INFRA-203 / INFRA-211: per-agent worker loop.
#
# One instance per fleet pane. Loops until killed:
#   1. git fetch + (best-effort) rebase main into a fresh worktree
#   2. ask musher.py / chump gap list for the next pickable gap
#      (filters: priority, domain, effort)
#   3. claim it via gap-claim.sh (atomic flock)
#   4. create a worktree at .claude/worktrees/<gap-id>-<sid>
#   5. spawn `claude -p <focused-prompt> --dangerously-skip-permissions`
#      with FLEET_TIMEOUT_S timeout — same surface as WorkBackend::Headless
#      in src/dispatch.rs (INFRA-191 Phase 2), used directly here because
#      `chump dispatch` does not yet expose the backend on the CLI.
#   6. on exit (success or failure): release lease, prune the worktree,
#      sleep IDLE_SLEEP_S if no gap was found, loop back.
#
# Env (set by run-fleet.sh, but each is overridable):
#   AGENT_ID                pane index (used in session id + logs)
#   REPO_ROOT               main checkout
#   FLEET_LOG_DIR           where to write per-cycle logs
#   FLEET_TIMEOUT_S         per-claude-call timeout (default 1800)
#   FLEET_PRIORITY_FILTER   default P0,P1
#   FLEET_DOMAIN_FILTER     default "" = any
#   FLEET_EFFORT_FILTER     default xs,s,m
#   IDLE_SLEEP_S            default 60 — sleep when no pickable gap

set -uo pipefail   # NOT -e: we want the loop to recover from individual cycle failures

AGENT_ID="${AGENT_ID:-?}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FLEET_LOG_DIR="${FLEET_LOG_DIR:-/tmp/chump-fleet-default}"
FLEET_TIMEOUT_S="${FLEET_TIMEOUT_S:-1800}"
FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1}"
FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"
IDLE_SLEEP_S="${IDLE_SLEEP_S:-60}"

mkdir -p "$FLEET_LOG_DIR"

log() { printf '[worker:%s %s] %s\n' "$AGENT_ID" "$(date -u +%H:%M:%S)" "$*"; }

trap 'log "interrupted; exiting loop"; exit 0' INT TERM

# Hard rule from CLAUDE.md: never auto-pickup these — they need human judgment.
EXCLUDE_PREFIXES_REGEX='^(EVAL-|RESEARCH-|META-)'

cd "$REPO_ROOT"

cycle=0
while :; do
    cycle=$((cycle + 1))
    log "cycle $cycle: fetching origin/main"
    git fetch origin main --quiet || log "WARN: git fetch failed; continuing"

    # ── Pick a gap ────────────────────────────────────────────────────────
    # We use `chump gap list --json` directly (musher.py has its own cooldown
    # heuristics; for fleet workers we want the simplest "highest-priority
    # unclaimed open gap matching filters" semantics so behavior is debuggable).
    gap_json="$(chump gap list --status open --json 2>/dev/null || echo '[]')"

    # Active leases (so we never try to claim something a sibling has).
    active_gaps="$(
        python3 - "$REPO_ROOT/.chump-locks" <<'PY' 2>/dev/null || true
import glob, json, sys, os
base = sys.argv[1]
for f in glob.glob(os.path.join(base, '*.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    g = d.get('gap_id') or (d.get('pending_new_gap') or {}).get('id')
    if g:
        print(g)
PY
    )"

    # Pick highest-priority candidate. Use a tempfile so we can send the gap
    # JSON on stdin AND keep the python script as a heredoc.
    gap_json_file="$(mktemp -t fleet-gaps.XXXXXX)"
    printf '%s' "$gap_json" > "$gap_json_file"
    pick="$(FLEET_PRIORITY_FILTER="$FLEET_PRIORITY_FILTER" \
            FLEET_DOMAIN_FILTER="$FLEET_DOMAIN_FILTER" \
            FLEET_EFFORT_FILTER="$FLEET_EFFORT_FILTER" \
            EXCLUDE_RE="$EXCLUDE_PREFIXES_REGEX" \
            ACTIVE_GAPS="$active_gaps" \
            GAP_JSON_FILE="$gap_json_file" \
            python3 "$REPO_ROOT/scripts/dispatch/_pick_gap.py" 2>/dev/null || true)"
    rm -f "$gap_json_file"

    if [ -z "$pick" ]; then
        log "no pickable gap (filters: prio=$FLEET_PRIORITY_FILTER domain=${FLEET_DOMAIN_FILTER:-any} effort=$FLEET_EFFORT_FILTER); sleeping ${IDLE_SLEEP_S}s"
        sleep "$IDLE_SLEEP_S"
        continue
    fi

    GAP_ID="$pick"
    log "picked gap $GAP_ID"

    # ── Worktree ──────────────────────────────────────────────────────────
    sid="$(date +%Y%m%d-%H%M%S)"
    gap_lower="$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')"
    wt_name="${gap_lower}-fleet-${AGENT_ID}-${sid}"
    wt_path="$REPO_ROOT/.claude/worktrees/$wt_name"
    branch="chump/${wt_name}"

    log "creating worktree $wt_path on branch $branch"
    if ! git -C "$REPO_ROOT" worktree add -b "$branch" "$wt_path" origin/main >/dev/null 2>&1; then
        log "WARN: worktree create failed for $GAP_ID; sleeping 30s"
        sleep 30
        continue
    fi

    # ── Claim ─────────────────────────────────────────────────────────────
    if ! ( cd "$wt_path" && CHUMP_AMBIENT_GLANCE=0 scripts/coord/gap-claim.sh "$GAP_ID" >/dev/null 2>&1 ); then
        log "WARN: gap-claim failed for $GAP_ID (sibling raced us?); cleaning up"
        git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
        continue
    fi

    # ── Spawn claude -p ───────────────────────────────────────────────────
    cycle_log="$FLEET_LOG_DIR/agent-${AGENT_ID}-cycle${cycle}-${GAP_ID}.log"
    prompt="Ship gap $GAP_ID in this repository. Read CLAUDE.md and AGENTS.md first. The gap is already claimed for this session; the lease is in .chump-locks/. Implement the gap per its description, commit via scripts/coord/chump-commit.sh, and ship via scripts/coord/bot-merge.sh --gap $GAP_ID --auto-merge. Reply with the PR number only."

    log "spawning claude -p (timeout ${FLEET_TIMEOUT_S}s) → $cycle_log"

    # Pick `timeout` (linux) or `gtimeout` (mac brew coreutils); fall back to none.
    if command -v timeout >/dev/null 2>&1; then
        TO="timeout ${FLEET_TIMEOUT_S}s"
    elif command -v gtimeout >/dev/null 2>&1; then
        TO="gtimeout ${FLEET_TIMEOUT_S}s"
    else
        TO=""
    fi

    (
        cd "$wt_path" || exit 99
        # Same surface as src/dispatch.rs WorkBackend::Headless.
        # shellcheck disable=SC2086
        $TO claude -p "$prompt" --dangerously-skip-permissions
    ) >"$cycle_log" 2>&1
    rc=$?

    if [ $rc -eq 0 ]; then
        log "claude exited cleanly for $GAP_ID"
    elif [ $rc -eq 124 ]; then
        log "WARN: claude timed out (${FLEET_TIMEOUT_S}s) on $GAP_ID"
    else
        log "WARN: claude exited rc=$rc on $GAP_ID"
    fi

    # ── Release lease + prune worktree ────────────────────────────────────
    # The lease will TTL-expire on its own; we also try to remove it cleanly.
    rm -f "$REPO_ROOT/.chump-locks/"*"${GAP_ID}"*.json 2>/dev/null || true

    # Worktree cleanup — keep it on disk if claude actually shipped a PR
    # (operator may want to inspect), otherwise remove. Simple proxy: if the
    # branch has been pushed (gone-status), prune; else leave for inspection.
    if git -C "$REPO_ROOT" branch -vv 2>/dev/null | grep -E "$branch" | grep -q ': gone\]'; then
        git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
        log "cleaned up worktree $wt_name (branch was gone — PR landed)"
    else
        log "leaving worktree $wt_name on disk (rc=$rc; inspect if needed)"
    fi

    # Brief gap between cycles so we don't hammer the API on a hot-loop bug.
    sleep 5
done
