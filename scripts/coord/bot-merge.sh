#!/usr/bin/env bash
#
# bot-merge.sh — Automated ship pipeline for agent branches.
#
# Intended for Claude sessions, Cursor agents, and the autonomy loop. Runs the
# full pre-merge checklist, pushes to origin, and opens (or updates) a GitHub PR.
#
# Usage:
#   scripts/coord/bot-merge.sh [--gap GAP-ID ...] [--stack-on PREV-GAP-ID] [--auto-merge] [--skip-tests] [--dry-run]
#
#   --stack-on PREV-GAP-ID
#                  Open this PR with base=<prev-PR-head> instead of main. When
#                  the prev PR lands, the merge queue auto-rebases this PR.
#                  Used for related work that would otherwise file-conflict if
#                  shipped in parallel (INFRA-061 / M3).
#
#   --gap GAP-ID   One or more gap IDs to check against origin/main before proceeding.
#                  If any gap is already `done` or claimed by another agent, the
#                  script aborts early. Repeat for multiple gaps: --gap A --gap B
#                  or pass space-separated: --gap "AUTO-003 COMP-002".
#   --auto-merge   Enable GitHub auto-merge on the PR (requires branch protection
#                  with required CI status checks configured).
#   --skip-tests   Skip `cargo test` (for pure-doc or non-Rust changes). fmt and
#                  clippy still run.
#   --fast         Skip BOTH cargo clippy AND cargo test locally. CI clippy/test
#                  is the gate (auto-merge won't land a red PR). Reduces total
#                  bot-merge wall time from ~5-10 min cold → ~30-60 sec, so
#                  agent-driven shipping fits inside the ~10-15 min subagent
#                  task budget. Implies --skip-tests. Default OFF; pass
#                  explicitly when running from chump dispatch / Agent tool /
#                  any context with a tight task budget. (INFRA-252)
#   --dry-run      Print every step without executing git push or gh commands.
#
# Requirements: gh CLI authenticated, GITHUB_TOKEN in env or gh keyring, cargo.
#
# Exit codes:
#   0  PR opened/updated (or already up to date)
#   1  Pre-flight check failed (gap preflight, fmt, clippy, tests)
#   2  Push or gh command failed
#   3  Branch too stale to merge safely (>40 commits behind main)

set -euo pipefail

# ── INFRA-119: health-file globals + cleanup traps ───────────────────────────
_BM_PID=$$
_BM_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_BM_HEALTH_FILE=""
_BM_STEP_FILE=""
_BM_HEALTH_PID=""
_BM_WATCHDOG_PID=""
_BM_CLEANUP_DONE=0

_bm_cleanup() {
    [[ "$_BM_CLEANUP_DONE" == "1" ]] && return
    _BM_CLEANUP_DONE=1
    [[ -n "${_BM_HEALTH_PID:-}" ]]   && kill "$_BM_HEALTH_PID"   2>/dev/null || true
    [[ -n "${_BM_WATCHDOG_PID:-}" ]] && kill "$_BM_WATCHDOG_PID" 2>/dev/null || true
    rm -f "${_BM_HEALTH_FILE:-}" "${_BM_STEP_FILE:-}" 2>/dev/null || true
}
trap '_bm_cleanup' EXIT
trap '_bm_cleanup; exit 1' TERM INT

# ── INFRA-017: dispatched-agent identity ─────────────────────────────────────
# When bot-merge.sh runs inside a dispatched subagent (chump-orchestrator set
# CHUMP_DISPATCH_DEPTH=1), stamp git author/committer so amend commits and
# any fresh commits we make are attributable to the bot — not the host
# developer's git config. Human invocations leave the env unset and keep
# the user's configured identity.
if [[ "${CHUMP_DISPATCH_DEPTH:-0}" == "1" ]]; then
    export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Chump Dispatched}"
    export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-chump-dispatch@chump.bot}"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-Chump Dispatched}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-chump-dispatch@chump.bot}"
fi

# ── INFRA-209: ensure pre-commit hooks are installed in this worktree ────────
# Cold Water Issue #10 audit (2026-05-02) found 8 commits on origin/main since
# 2026-05-01 introducing status:done with closed_pr:TBD — the INFRA-107 guard
# was supposed to block these but was bypassed because the remote dispatch
# agents had empty .git/hooks/ dirs. install-hooks.sh is per-worktree (post-
# checkout hook does it on `git worktree add` since INFRA-072) but ephemeral
# sandbox checkouts skip the post-checkout hook.
#
# Idempotent guard: if pre-commit is missing OR points at a path that no
# longer exists, run install-hooks.sh --quiet. This protects every bot-merge
# invocation regardless of how the worktree was created.
#
# Disable: CHUMP_AUTO_INSTALL_HOOKS=0
if [[ "${CHUMP_AUTO_INSTALL_HOOKS:-1}" != "0" ]]; then
    _bm_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _bm_git_dir="$(git rev-parse --git-dir 2>/dev/null || echo "$_bm_repo_root/.git")"
    _bm_hook="$_bm_git_dir/hooks/pre-commit"
    _bm_install_sh="$_bm_repo_root/scripts/setup/install-hooks.sh"
    _bm_needs_install=0
    if [[ ! -e "$_bm_hook" ]]; then
        _bm_needs_install=1
    elif [[ -L "$_bm_hook" ]] && [[ ! -e "$_bm_hook" ]]; then
        # symlink to a missing target (stale install from another machine)
        _bm_needs_install=1
    fi
    if [[ "$_bm_needs_install" == "1" ]] && [[ -x "$_bm_install_sh" ]]; then
        printf '\033[0;32m[bot-merge] INFRA-209: pre-commit hook missing, running install-hooks.sh\033[0m\n'
        "$_bm_install_sh" --quiet 2>&1 | sed 's/^/[bot-merge] /' || \
            printf '\033[0;31m[bot-merge] WARN: install-hooks.sh failed; continuing without hooks\033[0m\n'
    fi
fi

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_MERGE=0
SKIP_TESTS=0
FAST=0
DRY_RUN=0
GAP_IDS=()
NEXT_IS_GAP=0
# INFRA-061 (M3): --stack-on <PREV-GAP-ID> opens this PR with base=claude/<branch
# of the prev gap's open PR>, instead of base=main. When the prev PR lands, the
# merge queue auto-rebases this stacked PR onto the new main. One-deep stacks
# cover the dispatcher case; deeper stacks just chain (--stack-on the most
# recent open PR's gap).
STACK_ON_GAP=""
NEXT_IS_STACK_ON=0
for arg in "$@"; do
    if [[ $NEXT_IS_GAP -eq 1 ]]; then
        # Support --gap "AUTO-003 COMP-002" (space-separated) or --gap AUTO-003 --gap COMP-002
        for gid in $arg; do GAP_IDS+=("$gid"); done
        NEXT_IS_GAP=0
        continue
    fi
    if [[ $NEXT_IS_STACK_ON -eq 1 ]]; then
        STACK_ON_GAP="$arg"
        NEXT_IS_STACK_ON=0
        continue
    fi
    case "$arg" in
        --gap)         NEXT_IS_GAP=1 ;;
        --stack-on)    NEXT_IS_STACK_ON=1 ;;
        --auto-merge)  AUTO_MERGE=1 ;;
        --skip-tests)  SKIP_TESTS=1 ;;
        --fast)        FAST=1; SKIP_TESTS=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# INFRA-237: when --gap was not given, auto-derive from the current branch
# name. Branches following the canonical naming convention encode the gap ID
# (e.g. chump/infra-127-reflection-e2e → INFRA-127, claude/research-026-impl
# → RESEARCH-026, chore/file-infra-243 → INFRA-243). When auto-derive fires,
# print a clear info banner so the agent knows --gap was inferred (not
# silently skipped).
#
# The user can suppress auto-derivation by passing --gap none for genuine
# non-gap-bound PRs (e.g. dependabot bumps, doc-only sweeps that touch many
# unrelated areas). The literal string "none" filters out of GAP_IDS to keep
# downstream logic simple.
#
# Why this matters: when --gap is missing AND no auto-derive succeeds, the
# INFRA-154 auto-close path silently skips, producing the OPEN-BUT-LANDED
# ghosts INFRA-241 had to backfill. Making --gap effectively-required closes
# that path at the bottleneck without forcing every legitimate non-gap PR
# to add boilerplate.
if [[ ${#GAP_IDS[@]} -eq 0 ]]; then
    _branch_name=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    # Strip the canonical chump-codename prefixes (chump/, claude/, chore/file-,
    # chore/close-) so the regex catches IDs anywhere in the remainder.
    # Strip leading namespace token (chump/, claude/, chore/) and an optional
    # action prefix (file-, close-, fix-) — but NOT the domain prefix
    # (infra-, research-, etc.) because the domain IS the gap-ID prefix we
    # want to extract. Then turn dashes into spaces and uppercase so
    # 'infra-127-reflection' becomes 'INFRA 127 RELECTION' for the grep.
    _branch_tail=$(echo "$_branch_name" \
        | sed -E 's,^(chump|claude|chore)/(file-|close-|fix-)?,,' \
        | tr '-' ' ' | tr 'a-z' 'A-Z')
    # Extract every <DOMAIN>-<NUMBER> pattern from the cleaned branch name.
    _derived_gaps=$(echo "$_branch_tail" \
        | grep -oE '[A-Z]+ [0-9]+' \
        | sed 's/ /-/' \
        | sort -u | tr '\n' ' ')
    if [[ -n "$_derived_gaps" ]]; then
        for gid in $_derived_gaps; do GAP_IDS+=("$gid"); done
        printf '\033[0;32m[bot-merge] auto-derived --gap from branch name: %s\033[0m\n' "${GAP_IDS[*]}"
        printf '\033[0;32m[bot-merge]   (suppress with explicit --gap none for non-gap PRs)\033[0m\n'
    elif [[ -z "$_branch_name" ]]; then
        # Detached HEAD or non-branch state — let the script proceed; downstream
        # checks will fail loud if a gap is needed.
        :
    else
        echo "" >&2
        printf '\033[0;31m[bot-merge] ERROR: no --gap given and could not auto-derive from branch name "%s"\033[0m\n' "$_branch_name" >&2
        echo "[bot-merge]   INFRA-237: --gap is now effectively required to keep INFRA-154" >&2
        echo "[bot-merge]   auto-close working. Either:" >&2
        echo "[bot-merge]     1. Pass --gap explicitly: --gap INFRA-NNN" >&2
        echo "[bot-merge]     2. Rename the branch to encode the gap ID:" >&2
        echo "[bot-merge]          git branch -m chump/infra-NNN-<short>" >&2
        echo "[bot-merge]     3. Pass --gap none for genuine non-gap PRs" >&2
        echo "[bot-merge]        (dependabot bumps, doc-only sweeps, etc.)" >&2
        exit 2
    fi
fi

# Filter out the literal "none" sentinel — this is how callers explicitly
# suppress auto-derivation for non-gap PRs without tripping downstream checks
# that expect a real ID.
_filtered=()
for gid in "${GAP_IDS[@]}"; do
    [[ "$gid" == "none" || "$gid" == "NONE" ]] && continue
    _filtered+=("$gid")
done
# INFRA-237: ${_filtered[@]} expansion under `set -u` would error when the
# array is empty (e.g. caller passed --gap none). Reset GAP_IDS to an empty
# array first, then append only if there's anything to keep.
GAP_IDS=()
if [[ ${#_filtered[@]} -gt 0 ]]; then
    GAP_IDS=("${_filtered[@]}")
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
# INFRA-026 — timestamped banners let the fleet distinguish "stuck" from
# "working hard." Every green/red/info output carries `[bot-merge HH:MM:SS]`.
# Long stages use `stage_start <label>` → `stage_done` which prints the
# elapsed seconds. Silent intervals >30s are the symptom INFRA-026 was
# filed about; banners make them attributable.
green() { printf '\033[0;32m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
red()   { printf '\033[0;31m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
info()  { printf '[bot-merge %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

__STAGE_LABEL=""
__STAGE_T0=0
stage_start() {
    __STAGE_LABEL="$1"
    __STAGE_T0=$(date +%s)
    info "▶ $__STAGE_LABEL starting …"
    # INFRA-119: keep step file current so the health-file writer tracks progress
    [[ -n "${_BM_STEP_FILE:-}" ]] && printf '%s' "$__STAGE_LABEL" > "$_BM_STEP_FILE" 2>/dev/null || true
}
stage_done() {
    local elapsed=$(( $(date +%s) - __STAGE_T0 ))
    info "✓ $__STAGE_LABEL done (${elapsed}s)"
}

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] $*"
        return 0
    fi
    "$@"
}

# INFRA-028 — per-stage wall-clock timeouts (fleet contention / hung gh / cargo).
# Streams child output; on breach prints last lines via bot-merge-run-timed.py.
run_timed() {
    local max_secs=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] (timeout ${max_secs}s) $*"
        return 0
    fi
    python3 "$SCRIPT_DIR/bot-merge-run-timed.py" "$max_secs" -- "$@"
}

__HEARTBEAT_PID=""
heartbeat_end() {
    if [[ -n "${__HEARTBEAT_PID:-}" ]]; then
        kill "$__HEARTBEAT_PID" 2>/dev/null || true
        wait "$__HEARTBEAT_PID" 2>/dev/null || true
        __HEARTBEAT_PID=""
    fi
}

# Emit a line every 30s so parent watchers see progress during long subprocesses.
heartbeat_begin() {
    local label=$1
    (
        local t0
        t0=$(date +%s)
        while true; do
            sleep 30
            local now elapsed
            now=$(date +%s)
            elapsed=$((now - t0))
            info "… ${label} still running (${elapsed}s elapsed, heartbeat)"
        done
    ) &
    __HEARTBEAT_PID=$!
}

run_timed_hb() {
    local label=$1 max_secs=$2; shift 2
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] (timeout ${max_secs}s, heartbeat) $*"
        return 0
    fi
    heartbeat_begin "$label"
    set +e
    run_timed "$max_secs" "$@"
    local _rc=$?
    set -e
    heartbeat_end
    return "$_rc"
}

# ── INFRA-119: health-file writer + total-budget watchdog ────────────────────
# Call _bm_health_init once after REPO_ROOT is known. It:
#   1. Creates .chump-locks/bot-merge-<pid>.health — read by queue-health-monitor
#      to detect hangs when last_heartbeat_at goes > 5 min stale.
#   2. Starts a background loop that rewrites the health file every 30s with the
#      current stage label (read from .chump-locks/bot-merge-<pid>.step).
#   3. Starts a budget-watchdog: if CHUMP_BOT_MERGE_BUDGET_SECS (default 600)
#      elapses without the script completing, the watchdog emits an ambient
#      ALERT kind=bot_merge_hung and sends SIGTERM to this process.
#      Set to 0 to disable (e.g. for full cargo-test runs).
_bm_health_write() {
    [[ -z "${_BM_HEALTH_FILE:-}" ]] && return 0
    local step now
    step="$(cat "$_BM_STEP_FILE" 2>/dev/null || echo init)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"pid":%d,"started_at":"%s","current_step":"%s","last_heartbeat_at":"%s"}\n' \
        "$_BM_PID" "$_BM_STARTED_AT" "$step" "$now" \
        > "${_BM_HEALTH_FILE}.tmp" 2>/dev/null \
    && mv "${_BM_HEALTH_FILE}.tmp" "$_BM_HEALTH_FILE" 2>/dev/null || true
}

_bm_health_init() {
    local lock_dir="$1"
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$lock_dir" 2>/dev/null || true
    _BM_HEALTH_FILE="${lock_dir}/bot-merge-${_BM_PID}.health"
    _BM_STEP_FILE="${lock_dir}/bot-merge-${_BM_PID}.step"
    printf 'init' > "$_BM_STEP_FILE" 2>/dev/null || true
    _bm_health_write

    # Background heartbeat: rewrite health file every 30s
    local hf="$_BM_HEALTH_FILE" sf="$_BM_STEP_FILE"
    local pid="$_BM_PID" sa="$_BM_STARTED_AT"
    (
        while true; do
            sleep 30
            local step now
            step="$(cat "$sf" 2>/dev/null || echo unknown)"
            now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"pid":%d,"started_at":"%s","current_step":"%s","last_heartbeat_at":"%s"}\n' \
                "$pid" "$sa" "$step" "$now" \
                > "${hf}.tmp" && mv "${hf}.tmp" "$hf" || true
        done
    ) &
    _BM_HEALTH_PID=$!

    # Budget watchdog: SIGTERM + ambient ALERT if total runtime exceeds budget
    local budget="${CHUMP_BOT_MERGE_BUDGET_SECS:-600}"
    if [[ "$budget" -gt 0 ]]; then
        local ppid="$_BM_PID" ambient="${lock_dir}/ambient.jsonl"
        (
            sleep "$budget"
            local step now
            step="$(cat "$sf" 2>/dev/null || echo unknown)"
            now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"ts":"%s","session":"bot-merge-%d","event":"ALERT","kind":"bot_merge_hung","pid":%d,"step":"%s","note":"total budget %ss exceeded — sending SIGTERM"}\n' \
                "$now" "$ppid" "$ppid" "$step" "$budget" >> "$ambient" 2>/dev/null || true
            rm -f "$hf" 2>/dev/null || true
            kill -TERM "$ppid" 2>/dev/null || true
        ) &
        _BM_WATCHDOG_PID=$!
        disown "$_BM_WATCHDOG_PID" 2>/dev/null || true
    fi

    info "INFRA-119: health monitoring active (file=$(basename "$_BM_HEALTH_FILE") budget=${budget}s)"
}

# ── Repo context ──────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ── INFRA-224: ensure pre-commit hooks are installed before any commit ────────
# Cold Water Red Letter #10 (2026-05-02) found that fresh CCR sandboxes / new
# worktrees commit through bot-merge.sh WITHOUT the pre-commit hook installed,
# silently bypassing every guard (closed_pr integrity, gaps-yaml-discipline,
# duplicate-id, etc.). Result: 9 gaps shipped with `closed_pr: TBD` since
# 2026-05-01 alone. This block ensures the hook is present before we make any
# commits, so the guards always run.
#
# Cheap (a stat call); silent on the happy path. Bypass with
# CHUMP_INSTALL_HOOKS=0 if you really know what you're doing.
#
# NOTE: must use git's resolved git-dir, not "$REPO_ROOT/.git", because in a
# linked worktree .git is a file (gitdir pointer), not a directory. The hook
# we care about lives at <git-dir-for-this-worktree>/hooks/pre-commit.
if [[ "${CHUMP_INSTALL_HOOKS:-1}" == "1" ]] \
        && [[ -x "$REPO_ROOT/scripts/setup/install-hooks.sh" ]]; then
    _bm_git_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo "$REPO_ROOT/.git")"
    if [[ ! -x "$_bm_git_dir/hooks/pre-commit" ]]; then
        bash "$REPO_ROOT/scripts/setup/install-hooks.sh" --quiet 2>/dev/null \
            && echo "[bot-merge] installed pre-commit hooks (INFRA-224 first-run)" \
            || echo "[bot-merge] WARN: install-hooks.sh failed; pre-commit guards may be skipped" >&2
    fi
    unset _bm_git_dir
fi

# INFRA-017: attribute bot-merge synthetic commits (fmt amends, checkpoint tags)
# to the canonical dispatched-agent identity so Red Letter doesn't flag them as
# foreign-actor intrusions. Human sessions override with their own git config.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Chump Dispatched}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-chump-dispatch@chump.bot}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-Chump Dispatched}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-chump-dispatch@chump.bot}"

# ── Session-ID auto-detection ─────────────────────────────────────────────────
# gap-preflight reads CHUMP_SESSION_ID to distinguish "our" claim from others'.
# If not set, try to infer it from an existing gap lease file so the preflight
# recognises our own claim at ship time (the claim may have been written by a
# different shell with a different default session ID — e.g. CHUMP_SESSION_ID
# set explicitly during gap-claim.sh vs. ~/.chump/session_id at bot-merge time).
#
# INFRA-045 (2026-04-24): also match pending_new_gap.id, not just gap_id.
# For new gaps reserved via gap-reserve.sh, the caller's lease has a
# pending_new_gap reservation (gap isn't yet on origin/main). Without this
# match, bot-merge spawned a new session via its worktree-scoped fallback,
# post-rebase preflight ran under that new session (no pending_new_gap),
# and failed with "not found in docs/gaps.yaml" — forcing the INFRA-028
# manual path. Surfaced by PR #476 (PRODUCT-015).
if [[ -z "${CHUMP_SESSION_ID:-}" && ${#GAP_IDS[@]} -gt 0 ]]; then
    LOCK_DIR="$REPO_ROOT/.chump-locks"
    for _gid in "${GAP_IDS[@]}"; do
        for _lf in "$LOCK_DIR"/*.json; do
            [[ -f "$_lf" ]] || continue
            _match=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    if d.get('gap_id', '') == sys.argv[2]:
        print(d.get('session_id', ''))
    else:
        p = d.get('pending_new_gap')
        if isinstance(p, dict) and p.get('id', '') == sys.argv[2]:
            print(d.get('session_id', ''))
except Exception:
    pass
" "$_lf" "$_gid" 2>/dev/null || true)
            if [[ -n "$_match" ]]; then
                export CHUMP_SESSION_ID="$_match"
                info "Auto-detected session ID from gap lease: $CHUMP_SESSION_ID"
                break 2
            fi
        done
    done
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
    red "Detached HEAD — check out a branch first."
    exit 2
fi
if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    red "Already on $BRANCH. Run from a feature/agent branch."
    exit 2
fi

BASE_BRANCH="${BASE_BRANCH:-main}"
REMOTE="${REMOTE:-origin}"

# ── INFRA-119: start health monitoring now that REPO_ROOT is set ──────────────
_bm_health_init "$REPO_ROOT/.chump-locks"

# INFRA-061 (M3): if --stack-on <PREV-GAP> was passed, look up the open PR for
# that gap and use its head branch as our base. Falls back to main with a
# warning if the prev gap has no open PR (already landed → just stack on main).
if [[ -n "$STACK_ON_GAP" ]]; then
    info "Resolving --stack-on $STACK_ON_GAP via gh pr list …"
    _stack_branch=$(gh pr list --state open --search "$STACK_ON_GAP in:title,body" \
        --json number,headRefName --jq '.[0].headRefName' 2>/dev/null || echo "")
    if [[ -z "$_stack_branch" || "$_stack_branch" == "null" ]]; then
        info "No open PR found for $STACK_ON_GAP — falling back to base=main."
        info "(If the prev gap already landed, this is correct. Otherwise check the gap ID.)"
    else
        BASE_BRANCH="$_stack_branch"
        green "Stacking on PR for $STACK_ON_GAP — base=$BASE_BRANCH"
    fi
fi

green "=== bot-merge: $BRANCH → $BASE_BRANCH ==="

# ── 0a. Untracked-files guard ─────────────────────────────────────────────────
# Abort early if untracked files exist in source dirs — these won't appear in
# the PR diff and represent files the agent created but forgot to `git add`.
# Bypass: CHUMP_BOT_MERGE_ALLOW_UNTRACKED=1
if [[ "${CHUMP_BOT_MERGE_ALLOW_UNTRACKED:-0}" != "1" ]]; then
    untracked=$(git ls-files --others --exclude-standard src/ crates/ scripts/ docs/ 2>/dev/null)
    if [[ -n "$untracked" ]]; then
        red "ERROR: untracked files present — these won't be in your PR diff:"
        echo "$untracked"
        red "Stage them first (git add <file>), or bypass with CHUMP_BOT_MERGE_ALLOW_UNTRACKED=1"
        exit 1
    fi
fi

# ── 0. Gap pre-flight (abort if work is already done on main) ─────────────────
if [[ ${#GAP_IDS[@]} -gt 0 ]]; then
    info "Running gap pre-flight for: ${GAP_IDS[*]} …"
    if ! "$SCRIPT_DIR/gap-preflight.sh" "${GAP_IDS[@]}"; then
        red "Gap pre-flight failed — aborting to avoid duplicate work."
        red "The gaps are already done or claimed. Pick a different gap from docs/gaps.yaml."
        exit 1
    fi
    green "Gap pre-flight passed."

    # Write gap claim to lease file (replaces YAML in_progress edit — no merge conflicts).
    for gid in "${GAP_IDS[@]}"; do
        if [[ $DRY_RUN -eq 0 ]]; then
            "$SCRIPT_DIR/gap-claim.sh" "$gid"
        else
            info "[dry-run] gap-claim.sh $gid"
        fi
    done
fi

# ── 1. Fetch and rebase ───────────────────────────────────────────────────────
stage_start "git fetch $REMOTE/$BASE_BRANCH"
run_timed_hb "git fetch" 180 git fetch "$REMOTE" "$BASE_BRANCH" --quiet
stage_done

info "Fetched $REMOTE/$BASE_BRANCH."

BEHIND=$(git rev-list --count "HEAD..${REMOTE}/${BASE_BRANCH}" 2>/dev/null || echo 0)

# Hard abort if branch is extremely stale — rebase at 40+ commits is risky and
# likely means the work has already landed on main via another agent.
if [[ "$BEHIND" -gt 40 ]]; then
    red "Branch is $BEHIND commits behind $REMOTE/$BASE_BRANCH — too stale to merge safely."
    red "Run: scripts/coord/gap-preflight.sh ${GAP_IDS[*]:-<gap-ids>}"
    red "Then: git fetch && git rebase $REMOTE/$BASE_BRANCH (resolve conflicts)"
    red "If all your gaps are already done on main, close this branch instead."
    exit 3
fi

if [[ "$BEHIND" -gt 0 ]]; then
    stage_start "rebase on $REMOTE/$BASE_BRANCH ($BEHIND commit(s) behind)"
    if ! run_timed_hb "git rebase" 60 git rebase "${REMOTE}/${BASE_BRANCH}"; then
        red "git rebase failed or timed out — resolve conflicts or retry."
        exit 1
    fi
    stage_done

    # Re-check gap status after rebase: main may have merged the gap while we rebased.
    if [[ ${#GAP_IDS[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
        info "Re-checking gaps after rebase …"
        if ! "$SCRIPT_DIR/gap-preflight.sh" "${GAP_IDS[@]}"; then
            red "Gap was completed on main while we rebased — nothing left to push."
            exit 1
        fi
    fi
else
    info "Branch is up to date with $REMOTE/$BASE_BRANCH."
fi

# ── 2. cargo fmt ──────────────────────────────────────────────────────────────
if command -v cargo &>/dev/null && ls src/**/*.rs &>/dev/null 2>&1; then
    stage_start "cargo fmt"
    if ! run_timed_hb "cargo fmt" 120 cargo fmt --all; then
        red "cargo fmt failed or timed out."
        exit 1
    fi
    if [[ $DRY_RUN -eq 0 ]] && ! git diff --quiet; then
        info "cargo fmt changed files — staging and amending …"
        git add -u
        git commit --amend --no-edit --no-verify
        green "fmt fixes committed."
    fi
    stage_done
fi

# ── INFRA-164: parallelism + timeouts for cold-cache builds ───────────────────
# A cold workspace build of all rustc test/bin targets at default parallelism
# (= host logical CPUs, e.g. 10 on an M4) easily peaks past 16 GB RAM and gets
# rustc subprocesses SIGTERM'd by macOS Jetsam when the fleet has other
# concurrent worktrees building. The classic symptom is a sudden cascade of
# "(signal: 15, SIGTERM: termination signal)" across two or three rustc
# processes mid-build, with cargo reporting "build failed, waiting for other
# jobs to finish". That is not a real test failure — and it isn't a bot-merge
# timeout either; the wall-clock is fine. It is OOM pressure.
#
# Fix: limit cargo's parallelism. Default to 4 (safe for 24 GB / 10-core M4
# under fleet contention); operators with more headroom can raise via env.
#
# Separately: cold clippy alone takes ~8 minutes on this codebase. The
# previous 300s budget triggered TIMEOUT mid-compile — a real wall-clock
# hit, not OOM. Bumped to 900s (15 min). cargo test budget (3600s) was
# already generous enough for cold builds.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
info "cargo parallelism: CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} (override via env)"

# ── 3. cargo clippy ───────────────────────────────────────────────────────────
# Timeout 900s: cold workspace clippy is ~8 min on chump as of 2026-04-28.
#
# INFRA-252: --fast skips the local clippy step entirely. Rationale: cold
# workspace clippy is the long pole (5-8 min), busts the agent task budget
# (~10-15 min on Anthropic's general-purpose subagent) and forces the parent
# session to rescue commit-but-don't-push orphans. The GitHub Actions CI
# clippy job runs the same checks anyway and is the actual gate (auto-merge
# refuses to land a PR with red checks). With --fast, bot-merge.sh ships in
# ~30-60 sec total, comfortably inside any agent budget. Cost: a clippy-broken
# PR may briefly exist on the open-PR list before CI grades it red. Default
# OFF (preserves human-developer fail-fast ergonomics); agents pass --fast
# explicitly.
if [[ $FAST -eq 1 ]]; then
    info "Skipping local clippy (--fast). CI clippy is the gate."
elif command -v cargo &>/dev/null; then
    stage_start "cargo clippy --workspace --all-targets"
    if ! run_timed_hb "cargo clippy" 900 cargo clippy --workspace --all-targets -- -D warnings 2>&1; then
        red "clippy found errors — fix them before merging."
        exit 1
    fi
    stage_done
    green "clippy clean."
fi

# ── 4. cargo test ─────────────────────────────────────────────────────────────
if [[ $SKIP_TESTS -eq 0 ]] && command -v cargo &>/dev/null; then
    stage_start "cargo test --workspace"
    if ! run_timed_hb "cargo test" 3600 cargo test --workspace 2>&1; then
        red "Tests failed — fix them before merging."
        info "If you saw 'signal: 15, SIGTERM' across multiple rustc processes,"
        info "that is most likely OOM, not a real test failure. Try lowering"
        info "CARGO_BUILD_JOBS (currently ${CARGO_BUILD_JOBS}) and retry."
        exit 1
    fi
    stage_done
    green "Tests passed."
else
    info "Skipping tests (--skip-tests)."
fi

# ── 4a. CI shell-test gate for THIS PR's new/modified tests (INFRA-222) ──────
# `cargo test` covers Rust unit/integration tests but NOT the shell-script
# guard tests under `scripts/ci/test-*.sh`. PR #729 (INFRA-200) shipped with
# its own guard's test suite failing because bot-merge never ran the new
# `scripts/ci/test-raw-yaml-guard.sh` — CI caught it but the PR sat stuck.
#
# Strategy: run only the shell tests this PR adds or modifies. These are tests
# the PR author owns and should be passing locally before push. We skip the
# 38-test full sweep because many tests have implicit env dependencies (chump
# binary, ACP server, cursor CLI) that CI sets up but local worktrees don't.
#
# Bypass: CHUMP_SKIP_CI_SHELL=1 scripts/coord/bot-merge.sh ...
# Skipped automatically with --skip-tests.
if [[ $SKIP_TESTS -eq 0 ]] && [[ "${CHUMP_SKIP_CI_SHELL:-0}" != "1" ]]; then
    # Find shell tests added or modified relative to base branch
    BASE_REF="${CHUMP_BASE_REF:-origin/main}"
    CHANGED_TESTS=()
    while IFS= read -r f; do
        [[ -n "$f" && -f "$REPO_ROOT/$f" ]] && CHANGED_TESTS+=("$REPO_ROOT/$f")
    done < <(git diff --name-only --diff-filter=AM "$BASE_REF...HEAD" 2>/dev/null \
             | grep -E '^scripts/ci/test-.*\.sh$' || true)

    if [[ ${#CHANGED_TESTS[@]} -gt 0 ]]; then
        stage_start "PR-modified scripts/ci/test-*.sh (${#CHANGED_TESTS[@]} suites)"
        FAILED_TESTS=()
        for t in "${CHANGED_TESTS[@]}"; do
            tname="$(basename "$t")"
            if ! timeout 60 bash "$t" >/tmp/bot-merge-citest.log 2>&1; then
                FAILED_TESTS+=("$tname")
                red "  ✗ $tname"
                tail -10 /tmp/bot-merge-citest.log | sed 's/^/    /'
            fi
        done
        if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
            red "${#FAILED_TESTS[@]} CI shell test(s) failed: ${FAILED_TESTS[*]}"
            info "These are tests THIS PR adds/modifies. Fix locally before pushing —"
            info "they will block the PR's CI 'test' job otherwise (PR #729 was the"
            info "originating example — it sat stuck for 2+ hours waiting on a test"
            info "the author could have run in 5 seconds locally)."
            info "Bypass (only if you've already verified the failure is environmental):"
            info "  CHUMP_SKIP_CI_SHELL=1 scripts/coord/bot-merge.sh ..."
            exit 1
        fi
        stage_done
        green "All ${#CHANGED_TESTS[@]} PR-modified CI shell tests passed."
    fi
fi

# ── 4a-decomp. Decomposition advisory (FLEET-025 / FLEET-011 v0) ─────────────
# Surface heuristic-based decomposition hints for monolithic PRs. Per the
# FLEET-011 vision: file_count > 5 + LOC > 500 → consider decomposition.
# This is ADVISORY only (never blocks ship) — agents see the hint and decide
# whether to split or proceed. v0 emits the hint to stderr + ambient as
# kind=decomposition_hint so we can build a learning loop later (track
# whether agents heeded the hint vs proceeded; bias future hints).
#
# Bypass: CHUMP_DECOMP_HINT=0 (silence entirely)
# Tune:   CHUMP_DECOMP_FILE_THRESHOLD (default 5), CHUMP_DECOMP_LOC_THRESHOLD (default 500)
if [[ "${CHUMP_DECOMP_HINT:-1}" != "0" ]]; then
    DECOMP_FILES_T="${CHUMP_DECOMP_FILE_THRESHOLD:-5}"
    DECOMP_LOC_T="${CHUMP_DECOMP_LOC_THRESHOLD:-500}"
    DECOMP_BASE="${CHUMP_BASE_REF:-origin/main}"
    DECOMP_FILES="$(git diff --name-only --diff-filter=AM "$DECOMP_BASE...HEAD" 2>/dev/null | wc -l | tr -d ' ')"
    DECOMP_LOC="$(git diff --shortstat "$DECOMP_BASE...HEAD" 2>/dev/null \
                  | awk '{ins=0;del=0; for(i=1;i<=NF;i++){if($i~/insertion/)ins=$(i-1); if($i~/deletion/)del=$(i-1)} print ins+del}')"
    DECOMP_LOC="${DECOMP_LOC:-0}"

    # Heuristic exemptions: codemod-style changes (gap registry regen, lockfile
    # bumps, mass formatting) shouldn't trigger because they're already atomic
    # by intent. Detect by checking if >80% of touched files are in known
    # codemod paths.
    DECOMP_CODEMOD="$(git diff --name-only --diff-filter=AM "$DECOMP_BASE...HEAD" 2>/dev/null \
                     | grep -cE '^(docs/gaps/|\.chump/state\.sql|Cargo\.lock|book/src/)' || echo 0)"
    DECOMP_CODEMOD_RATIO=0
    if [[ "$DECOMP_FILES" -gt 0 ]]; then
        DECOMP_CODEMOD_RATIO=$(( DECOMP_CODEMOD * 100 / DECOMP_FILES ))
    fi

    if [[ "$DECOMP_FILES" -gt "$DECOMP_FILES_T" ]] && [[ "$DECOMP_LOC" -gt "$DECOMP_LOC_T" ]] \
       && [[ "$DECOMP_CODEMOD_RATIO" -lt 80 ]]; then
        warn "decomposition hint: ${DECOMP_FILES} files, ${DECOMP_LOC} LOC changed"
        info "  thresholds: > ${DECOMP_FILES_T} files AND > ${DECOMP_LOC_T} LOC (FLEET-011 v0 heuristic)"
        info "  consider: split by subsystem / per-file / 'land then migrate' stack — not blocking, just a nudge"
        info "  silence: CHUMP_DECOMP_HINT=0 scripts/coord/bot-merge.sh ..."
        # Best-effort emit to ambient so we can build the learning loop later
        if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
            "$REPO_ROOT/scripts/dev/ambient-emit.sh" decomposition_hint \
                "kind=oversize" \
                "files=$DECOMP_FILES" \
                "loc=$DECOMP_LOC" \
                "gap=${GAP_ID:-unknown}" \
                "branch=$BRANCH" 2>/dev/null || true
        fi
    fi
fi

# ── 4b. Ambient glance (INFRA-083) ───────────────────────────────────────────
# Final peripheral-vision check before push: surface any sibling that already
# committed or pushed against the same gap (race window between gap-claim and
# now). Hard-stop if a sibling commit for this gap landed in the last 120s.
if [[ -n "${GAP_ID:-}" ]] && [[ -x "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" ]] \
   && [[ "${CHUMP_AMBIENT_GLANCE:-1}" != "0" ]]; then
    if ! "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" --gap "$GAP_ID" --since-secs 600 --limit 5 --check-overlap; then
        red "Sibling activity collision on $GAP_ID — aborting push. Re-tail ambient.jsonl, re-plan, re-run."
        info "Bypass: CHUMP_AMBIENT_GLANCE=0 scripts/coord/bot-merge.sh ..."
        exit 2
    fi
fi

# ── 5. Push ───────────────────────────────────────────────────────────────────
stage_start "git push $BRANCH → $REMOTE"
if ! run_timed_hb "git push" 120 git push "$REMOTE" "$BRANCH" --force-with-lease; then
    red "git push failed or timed out."
    exit 2
fi
stage_done
green "Pushed."

# ── 5b. INFRA-084 advisory: warn if PR diff hand-edits docs/gaps.yaml ───────
# The merge_group workflow `.github/workflows/regenerate-gaps-yaml.yml`
# auto-regenerates the YAML from .chump/state.db on every queue temp branch,
# so most hand-edits are unnecessary now. Common case where this matters:
#   - filing PRs that append a new gap entry by hand instead of using
#     `chump gap reserve`
#   - closure PRs that hand-edit status:done instead of running
#     `chump gap ship --closed-pr <N> --update-yaml`
# Advisory-only for now; INFRA-094 will block these in pre-commit once the
# merge_group regen is fully validated.
if [[ "${CHUMP_RAW_YAML_EDIT_CHECK:-1}" != "0" ]]; then
    if git diff --name-only "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null \
        | grep -qx 'docs/gaps.yaml'; then
        info "[bot-merge] NOTE: this PR's diff includes docs/gaps.yaml hand-edits."
        info "[bot-merge]   Prefer: chump gap reserve / set / ship --update-yaml so the canonical"
        info "[bot-merge]   regenerator (.github/workflows/regenerate-gaps-yaml.yml) round-trips"
        info "[bot-merge]   the diff cleanly. The merge_group workflow will auto-fix any drift."
        info "[bot-merge]   Suppress this notice: CHUMP_RAW_YAML_EDIT_CHECK=0"
    fi
fi

# ── 6. Open or update PR ─────────────────────────────────────────────────────
EXISTING_PR=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")

if [[ -z "$EXISTING_PR" ]]; then
    stage_start "gh pr create"
    # Build a body from the gap IDs cited in commits since base diverged.
    COMMIT_LOG=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline 2>/dev/null | head -20)
    COMMIT_GAP_IDS=$(echo "$COMMIT_LOG" | grep -oE '[A-Z]+-[0-9]+' | sort -u | tr '\n' ' ' || true)
    GAP_LINE=""
    [[ -n "$COMMIT_GAP_IDS" ]] && GAP_LINE="**Gaps addressed:** $COMMIT_GAP_IDS"

    PR_TITLE=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | tail -1 | sed 's/^[a-f0-9]* //')

    # INFRA-060 (M2): if a `.chump-plans/<gap>.md` exists for any gap cited in
    # commit messages, splice its body verbatim into the PR description so
    # reviewers can see the planned files + open-PR overlap scan.
    PLAN_BLOCK=""
    for gid in $COMMIT_GAP_IDS; do
        plan_file=".chump-plans/${gid}.md"
        if [[ -f "$plan_file" ]]; then
            PLAN_BLOCK+="$(printf '\n\n<details><summary>Plan-mode (%s)</summary>\n\n%s\n\n</details>' "$gid" "$(cat "$plan_file")")"
        fi
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] gh pr create --base $BASE_BRANCH --title \"$PR_TITLE\" …"
    else
        if ! run_timed_hb "gh pr create" 120 gh pr create \
            --base "$BASE_BRANCH" \
            --title "$PR_TITLE" \
            --body "$(cat <<EOF
## Changes
$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | sed 's/^/- /')

${GAP_LINE}
${PLAN_BLOCK}

## Checklist
- [x] \`cargo fmt\` clean
- [x] \`cargo clippy\` clean
$([ $SKIP_TESTS -eq 0 ] && echo "- [x] \`cargo test\` passed" || echo "- [ ] tests skipped (non-Rust change)")

🤖 Opened by bot-merge.sh
EOF
)"; then
            red "gh pr create failed or timed out."
            exit 2
        fi
        _new_pr=""
        for _try in 1 2 3 4 5; do
            _new_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
            [[ -n "$_new_pr" ]] && break
            sleep 2
        done
        if [[ -z "$_new_pr" ]]; then
            red "gh pr create reported success but no PR is visible for branch $BRANCH — refusing to exit 0."
            exit 2
        fi
        stage_done
        green "PR #$_new_pr created and verified."
    fi
else
    green "PR #$EXISTING_PR already exists — updated by push."
fi

# ── 6.75. Auto-close gap on the implementation PR (INFRA-154) ────────────────
# Before arming auto-merge, fold the gap status flip INTO the implementation PR.
# Without this, every shipped gap needed a separate "flip status to done after
# PR #N landed" follow-up commit (5+ such bot-effort PRs in the week of
# 2026-04-22..28: #617, #623, #627, #630, #632, #634). The merge queue squashes
# the close commit together with the implementation commit, so origin/main sees
# one atomic closure with status=done + closed_pr=<this PR's number>.
#
# Disable with CHUMP_AUTO_CLOSE_GAP=0 for genuine partial-progress / split PRs
# where the gap is NOT being fully closed by this ship.
#
# Skipped when:
#   - DRY_RUN
#   - --no-auto-merge (no PR number to attach)
#   - GAP_IDS array is empty (--gap was not given)
#   - TARGET_PR couldn't be determined from gh pr view
#   - chump binary missing or `chump gap ship` fails (often: gap already done)
if [[ $DRY_RUN -eq 0 ]] && [[ $AUTO_MERGE -eq 1 ]] && [[ "${CHUMP_AUTO_CLOSE_GAP:-1}" != "0" ]] && [[ ${#GAP_IDS[@]} -gt 0 ]]; then
    _autoclose_target_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    if [[ -n "$_autoclose_target_pr" ]] && command -v chump >/dev/null 2>&1; then
        for _gid in "${GAP_IDS[@]}"; do
            stage_start "auto-close gap $_gid via PR #$_autoclose_target_pr (INFRA-154)"
            if chump gap ship "$_gid" \
                    --closed-pr "$_autoclose_target_pr" \
                    --update-yaml >/dev/null 2>&1; then
                # Regenerate the readable SQL dump so the diff is reviewable.
                chump gap dump --out .chump/state.sql >/dev/null 2>&1 || true
                # Stage only the files we expect this command to have touched.
                # If nothing changed (e.g. gap already done), skip the commit.
                # INFRA-226: post-INFRA-188-cutover the monolithic docs/gaps.yaml
                # may not exist anymore — gaps live in docs/gaps/<ID>.yaml.
                # Stat both paths so the auto-close commit picks up whichever
                # mirror chump gap ship --update-yaml wrote into. Conditional
                # `git add` calls avoid the `pathspec did not match any files`
                # fatal that previously aborted bot-merge BEFORE auto-merge
                # arming, leaving every post-cutover PR un-armed (PR #759 etc).
                _autoclose_changed=$(git status --porcelain docs/gaps.yaml docs/gaps/ .chump/state.sql 2>/dev/null || echo "")
                if [[ -n "$_autoclose_changed" ]]; then
                    [[ -f docs/gaps.yaml ]] && git add docs/gaps.yaml
                    [[ -d docs/gaps ]]      && git add docs/gaps/
                    [[ -f .chump/state.sql ]] && git add .chump/state.sql
                    git commit -m "chore(close): auto-close $_gid via PR #$_autoclose_target_pr (INFRA-154)" \
                               --no-verify >/dev/null 2>&1 || {
                        yellow "Auto-close commit failed for $_gid — leaving the PR as-is"
                        stage_done
                        continue
                    }
                    if ! run_timed_hb "git push (auto-close)" 120 git push origin "$BRANCH"; then
                        yellow "Auto-close push failed for $_gid — the close commit is local only"
                    else
                        green "Auto-closed $_gid (closed_pr=$_autoclose_target_pr) — squashed atomically by merge queue"
                        # INFRA-192: forward-chain notifier. When a gap closes,
                        # scan open gaps for `depends_on` entries containing
                        # this ID; emit a `gap_unblocked` ambient event for
                        # each downstream so sibling agents can pick them up
                        # immediately (instead of via manual queue-scan or
                        # cycle-by-cycle Cold Water sweep).
                        # Best-effort: never blocks the close path.
                        if command -v chump >/dev/null 2>&1 \
                            && [[ -x scripts/coord/broadcast.sh ]]; then
                            _unblocked=$(chump gap list --status open --json 2>/dev/null \
                                | python3 -c "
import json, sys
gid = '$_gid'
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for g in data:
    deps = g.get('depends_on') or []
    if isinstance(deps, str):
        deps = [d.strip() for d in deps.split(',') if d.strip()]
    if gid in deps:
        print(g['id'])
" 2>/dev/null || true)
                            if [[ -n "$_unblocked" ]]; then
                                _unblocked_count=0
                                while IFS= read -r _down; do
                                    [[ -z "$_down" ]] && continue
                                    scripts/coord/broadcast.sh ALERT \
                                        kind=gap_unblocked \
                                        "INFRA-192: $_gid closed (PR #$_autoclose_target_pr) — $_down newly actionable (depends_on link satisfied)" \
                                        >/dev/null 2>&1 || true
                                    _unblocked_count=$((_unblocked_count + 1))
                                done <<< "$_unblocked"
                                green "Forward-chain (INFRA-192): $_gid unblocked ${_unblocked_count} downstream gap(s); broadcast to siblings"
                            fi
                        fi
                    fi
                else
                    info "Auto-close: $_gid produced no diff (likely already status=done)"
                fi
            else
                info "Auto-close skipped for $_gid (chump gap ship failed; gap may already be done or have no entry)"
            fi
            stage_done
        done
    fi
fi

# ── 7. Enable auto-merge (optional) ──────────────────────────────────────────
if [[ $AUTO_MERGE -eq 1 ]]; then
    TARGET_PR="${EXISTING_PR:-}"
    if [[ -z "$TARGET_PR" ]]; then
        TARGET_PR=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    fi
    if [[ -n "$TARGET_PR" ]]; then
        # ── 6.5 Code-reviewer agent gate (INFRA-AGENT-CODEREVIEW MVP) ────────
        # If the PR touches src/* or crates/*/src/*, run the code-reviewer
        # agent before enabling auto-merge. APPROVE/SKIP -> proceed; CONCERN
        # or ESCALATE blocks the auto-merge so a human can resolve.
        # Bypass with CHUMP_CODEREVIEW=0 (e.g. infra/scripts changes).
        if [[ "${CHUMP_CODEREVIEW:-1}" != "0" ]] && [[ -x "$SCRIPT_DIR/code-reviewer-agent.sh" ]]; then
            CHANGED=$(gh pr diff "$TARGET_PR" --name-only 2>/dev/null || echo "")
            TOUCHES_SRC=0
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if [[ "$f" =~ ^src/ ]] || [[ "$f" =~ ^crates/.*/src/ ]]; then
                    TOUCHES_SRC=1; break
                fi
            done <<< "$CHANGED"

            if [[ $TOUCHES_SRC -eq 1 ]]; then
                info "PR #$TARGET_PR touches src/* — invoking code-reviewer-agent.sh …"
                _gap_arg=""
                [[ ${#GAP_IDS[@]} -gt 0 ]] && _gap_arg="--gap ${GAP_IDS[0]}"
                set +e
                "$SCRIPT_DIR/code-reviewer-agent.sh" "$TARGET_PR" $_gap_arg --post
                _rc=$?
                set -e
                case $_rc in
                    0|3)
                        green "Code-reviewer verdict: APPROVE/SKIP — proceeding with auto-merge." ;;
                    1)
                        red "Code-reviewer raised CONCERN — auto-merge NOT enabled."
                        red "Resolve concerns then run: gh pr merge $TARGET_PR --auto --squash"
                        exit 1 ;;
                    2)
                        red "Code-reviewer ESCALATED — human review required, auto-merge NOT enabled."
                        exit 1 ;;
                    *)
                        red "Code-reviewer agent errored (exit $_rc) — auto-merge NOT enabled."
                        exit 1 ;;
                esac
            else
                info "PR #$TARGET_PR is non-src — code-reviewer skipped (auto-merge proceeds)."
            fi
        fi

        # ── Pre-merge CI gate (INFRA-CHOKE prevention) ────────────────────────────
        # Before arming auto-merge, verify that all required CI checks are passing.
        # If Release job or Crate Publish dry-run are failing, abort with a diagnostic
        # message and commit a comment to the PR so the developer sees the blocker.
        # (This prevents PR #470-style situations where auto-merge is armed on a PR
        # that's waiting for shared infrastructure to be fixed.)
        stage_start "CI status pre-flight check"
        _ci_status=$(gh pr checks "$TARGET_PR" 2>/dev/null | grep -E "FAILURE|ERROR" || true)
        if [[ -n "$_ci_status" ]]; then
            red "BLOCKER: Required CI jobs failed. Not arming auto-merge."
            red "Failed checks:"
            echo "$_ci_status" | sed 's/^/  /'

            # Post a comment to the PR so the developer sees the blocker.
            # NOTE: previously built with $(cat <<'EOF' ...), which hits a bash
            # pre-parser bug — inside $(...) the backtick-balance scanner still
            # runs across the heredoc body even when the delimiter is quoted,
            # so literal triple-backticks in the markdown fence caused
            # "line NNN: unexpected EOF while looking for matching `". That
            # aborted bot-merge *after* PR create but *before* the auto-merge
            # arm step, silently dropping PRs into the queue without --auto.
            # See: PR #482/#488/#491 (2026-04-24). The fix: build the body
            # with printf + a backtick variable, so no un-escaped backticks
            # ever appear inside a $(...) literal.
            _fence='```'
            printf -v _comment_body '%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n' \
                '⚠️ Auto-merge blocked: Required CI checks failed.' \
                '**Failing checks:**' \
                "${_fence}" \
                "${_ci_status}" \
                "${_fence}" \
                '**Next steps:**' \
                '1. Investigate the failing check (click the link in the GitHub UI)' \
                '2. Fix the underlying issue (usually in Release job or infrastructure)' \
                "3. Once all checks pass, re-run: \`scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge\`"
            if [[ $DRY_RUN -eq 0 ]]; then
                gh pr comment "$TARGET_PR" -b "$_comment_body" 2>/dev/null || true
            fi
            exit 1
        fi
        green "All required CI checks passing — proceeding with auto-merge."
        stage_done

        # Pre-merge checkpoint tag (2026-04-18 PR #52 retrospective).
        # GitHub squash-merge captures branch state at the moment CI
        # passes and drops any commits pushed after — losing 11 commits
        # on PR #52, recovery via PR #65 was forced. This tag pins the
        # branch HEAD at the moment we enable auto-merge, so recovery is
        # `git checkout pr-NN-checkpoint` (vs. having to fetch the
        # orphaned branch and cherry-pick). Disable with
        # CHUMP_PRE_MERGE_CHECKPOINT=0.
        if [[ "${CHUMP_PRE_MERGE_CHECKPOINT:-1}" != "0" ]]; then
            CHECKPOINT_TAG="pr-${TARGET_PR}-checkpoint"
            if ! git rev-parse --quiet --verify "refs/tags/${CHECKPOINT_TAG}" >/dev/null; then
                info "Pinning checkpoint tag ${CHECKPOINT_TAG} (squash-loss insurance) …"
                run_timed 60 git tag "${CHECKPOINT_TAG}" HEAD
                if ! run_timed_hb "git push checkpoint tag" 120 git push origin "${CHECKPOINT_TAG}"; then
                    red "Failed to push checkpoint tag ${CHECKPOINT_TAG}."
                    exit 2
                fi
                green "Checkpoint tag pushed — recovery via 'git checkout ${CHECKPOINT_TAG}'."
            else
                info "Checkpoint tag ${CHECKPOINT_TAG} already exists — skipping."
            fi
        fi

        stage_start "gh pr merge #$TARGET_PR --auto --squash"
        if ! run_timed_hb "gh pr merge" 120 gh pr merge "$TARGET_PR" --auto --squash; then
            red "gh pr merge failed or timed out."
            exit 2
        fi
        stage_done
        green "Auto-merge enabled — PR will land when CI passes."

        # INFRA-190: fire-and-forget pr-watch.sh so the PR auto-recovers
        # if main moves while it's queued (DIRTY → rebase + force-push +
        # re-arm). The script handles the 80% case (no real conflicts);
        # real conflicts surface to the operator via exit 3.
        # Default ON; opt out with CHUMP_PR_WATCH_AFTER_ARM=0 (e.g. when
        # the operator wants to babysit the PR manually).
        if [[ "${CHUMP_PR_WATCH_AFTER_ARM:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/coord/pr-watch.sh" ]]; then
            _watch_log="/tmp/pr-watch-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/coord/pr-watch.sh" "$TARGET_PR" \
                > "$_watch_log" 2>&1 &
            _watch_pid=$!
            disown "$_watch_pid" 2>/dev/null || true
            info "pr-watch.sh detached (pid $_watch_pid, log $_watch_log) — PR will auto-recover from DIRTY"
        fi

        # INFRA-223: feed the chump_improvement_targets loop after every
        # shipped PR. distill-pr-skills.sh shipped in PR #712 but produces 0
        # rows in production because no scheduler fires it (Cold Water #10
        # finding). Hook it into bot-merge's post-arm step so every shipped
        # PR feeds the loop. Background (&) so a slow gh-api call doesn't
        # block the bot-merge happy path; bypass via existing CHUMP_DISTILL=0
        # env var (already supported by the script) or CHUMP_DISTILL_AFTER_SHIP=0
        # to disable just the bot-merge hook without affecting manual runs.
        if [[ "${CHUMP_DISTILL_AFTER_SHIP:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/ops/distill-pr-skills.sh" ]] \
            && [[ -n "$TARGET_PR" ]]; then
            _distill_log="/tmp/distill-pr-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/ops/distill-pr-skills.sh" --pr "$TARGET_PR" \
                > "$_distill_log" 2>&1 &
            _distill_pid=$!
            disown "$_distill_pid" 2>/dev/null || true
            info "distill-pr-skills.sh detached (pid $_distill_pid, log $_distill_log) — feeds chump_improvement_targets"
        fi
    fi
fi

# INFRA-028 — exit-code honesty: never finish "success" without a visible PR.
if [[ $DRY_RUN -eq 0 ]]; then
    _verify_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    if [[ -z "$_verify_pr" ]]; then
        red "No GitHub PR found for branch $BRANCH — refusing to exit 0."
        exit 2
    fi
fi

# ── 8. Write shipped-marker (INFRA-BOT-MERGE-LOCK) ───────────────────────────
# Presence of .bot-merge-shipped causes chump-commit.sh to refuse further
# commits in this worktree — enforcing the "PR frozen once shipped" rule from
# the PR #52 retrospective. The worktree-reaper (INFRA-WORKTREE-REAPER) treats
# this file as "definitely safe to remove" when cleaning up old worktrees.
if [[ $DRY_RUN -eq 0 ]]; then
    _shipped_pr="${TARGET_PR:-${EXISTING_PR:-}}"
    if [[ -z "$_shipped_pr" ]]; then
        # PR may have been created in this run; fetch it now.
        _shipped_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    fi
    _shipped_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > .bot-merge-shipped <<EOF
PR_NUMBER=${_shipped_pr:-unknown}
SHIPPED_AT=${_shipped_at}
BRANCH=${BRANCH}
# Worktree-reaper: safe to remove this worktree
EOF
    green "Wrote .bot-merge-shipped — this worktree is now frozen (no further commits)."

    # INFRA-017: purge ./target in the frozen worktree. Each Rust target/ is
    # 1.4–9 GB; with ~25 frozen worktrees the 460 GB disk fills and subsequent
    # ship runs fail at clippy with `No space left on device (os error 28)`.
    # The PR is already pushed — no further clippy/test runs need this cache.
    # Override with CHUMP_KEEP_TARGET=1 to poke around post-ship.
    if [[ "${CHUMP_KEEP_TARGET:-0}" != "1" && -d "./target" ]]; then
        info "Purging ./target in frozen worktree (set CHUMP_KEEP_TARGET=1 to keep)…"
        run rm -rf ./target
        green "Removed ./target — disk reclaimed."
    fi
fi

green "=== bot-merge done. ==="
