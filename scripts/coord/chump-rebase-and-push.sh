#!/usr/bin/env bash
# scripts/coord/chump-rebase-and-push.sh — INFRA-1404
#
# Atomic fetch → rebase (with merge drivers) → force-with-lease push.
# Replaces the 5-step manual recipe operators ran 4× on 2026-05-16.
#
# Usage:
#   chump-rebase-and-push.sh [<base-ref>] [--remote <name>] [--interactive]
#                            [--dry-run] [--no-merge-driver]
#
# Arguments:
#   <base-ref>          Branch/ref to rebase onto. Default: main
#   --remote <name>     Git remote. Default: chump, then origin
#   --interactive       Pass -i to git rebase (launches $EDITOR for rebase todo)
#   --dry-run           Print commands without executing push or rebase
#   --no-merge-driver   Disable custom merge drivers (e.g. in CI with clean tree)
#
# Exit codes:
#   0   success — branch is rebased + pushed
#   1   fatal error (wrong branch, no remote, etc.)
#   2   unresolvable conflict after merge drivers — operator must resolve manually
#   3   force-with-lease rejected twice — sibling pushed in the meantime; re-run
#
# Emits kind=rebase_and_push_invoked to ambient.jsonl (INFRA-1404).
#
# NOTE: This script mutates branch history. Never run on main.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CHUMP_REPO_ROOT lets tests point the script at a synthetic repo instead of
# the real chump checkout. In production, falls back to the chump worktree.
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ── Source ambient-write helper ───────────────────────────────────────────────
AMBIENT_LIB="${SCRIPT_DIR}/lib/ambient-write.sh"
if [[ -f "$AMBIENT_LIB" ]]; then
    # shellcheck source=scripts/coord/lib/ambient-write.sh disable=SC1091
    source "$AMBIENT_LIB"
else
    _ambient_write() { printf '%s\n' "$2" >> "$1" 2>/dev/null || true; }
fi

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"

# ── Colour helpers ────────────────────────────────────────────────────────────
_tty() { [[ -t 2 ]]; }
red()  { _tty && printf '\033[0;31m%s\033[0m\n' "$*" >&2 || printf '%s\n' "$*" >&2; }
grn()  { _tty && printf '\033[0;32m%s\033[0m\n' "$*" >&2 || printf '%s\n' "$*" >&2; }
info() { _tty && printf '\033[0;36m[rap]\033[0m %s\n' "$*" >&2 || printf '[rap] %s\n' "$*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
BASE_REF="main"
REMOTE=""
INTERACTIVE=0
DRY_RUN=0
NO_MERGE_DRIVER=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)       REMOTE="$2"; shift 2 ;;
        --interactive)  INTERACTIVE=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --no-merge-driver) NO_MERGE_DRIVER=1; shift ;;
        --*)            red "Unknown flag: $1"; exit 1 ;;
        *)              BASE_REF="$1"; shift ;;
    esac
done

# ── Detect remote ─────────────────────────────────────────────────────────────
if [[ -z "$REMOTE" ]]; then
    if git remote get-url chump >/dev/null 2>&1; then
        REMOTE="chump"
    elif git remote get-url origin >/dev/null 2>&1; then
        REMOTE="origin"
    else
        red "No 'chump' or 'origin' remote found. Set --remote <name>."
        exit 1
    fi
fi

# ── Detect current branch ─────────────────────────────────────────────────────
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [[ -z "$BRANCH" ]] || [[ "$BRANCH" == "HEAD" ]]; then
    red "Detached HEAD — cannot rebase-and-push. Checkout a branch first."
    exit 1
fi
if [[ "$BRANCH" == "main" ]] || [[ "$BRANCH" == "master" ]]; then
    red "Refusing to force-push to '$BRANCH'. Checkout a feature branch."
    exit 1
fi

FULL_BASE="${REMOTE}/${BASE_REF}"
info "branch=$BRANCH  base=$FULL_BASE  remote=$REMOTE  dry-run=$DRY_RUN"

# ── Emit helper ───────────────────────────────────────────────────────────────
_emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local json
    json="$(printf '{"ts":"%s","kind":"%s","branch":"%s","base":"%s","remote":"%s"%s}' \
        "$ts" "$kind" "$BRANCH" "$FULL_BASE" "$REMOTE" "${extra:+,$extra}")"
    _ambient_write "$AMBIENT_LOG" "$json"
}

# ── Ensure working tree is clean ──────────────────────────────────────────────
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    red "Working tree has uncommitted changes. Stash or commit them first."
    red "  git stash && chump-rebase-and-push.sh && git stash pop"
    exit 1
fi

# ── Merge-driver rebase args ──────────────────────────────────────────────────
_rebase_args=()
if [[ "$INTERACTIVE" == "1" ]]; then
    _rebase_args+=(-i)
else
    # Non-interactive: use identity sequence editor so rebase proceeds automatically
    export GIT_SEQUENCE_EDITOR=":"
fi
if [[ "$NO_MERGE_DRIVER" == "1" ]]; then
    _rebase_args+=(
        -c merge.ci-yml-add-row.driver=
        -c merge.pre-commit-add-guard.driver=
        -c merge.chump-state-sql-regen.driver=
        -c merge.gap-yaml-add-line.driver=
        -c merge.cargo-toml-append.driver=
        -c merge.js-append.driver=
    )
fi

# ── Step 1: fetch ─────────────────────────────────────────────────────────────
_rap_fetch() {
    info "Fetching $REMOTE …"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] git fetch $REMOTE $BASE_REF"
        return 0
    fi
    git -C "$REPO_ROOT" fetch "$REMOTE" "$BASE_REF" --quiet
}

# ── Step 2: rebase (returns 0=clean, 2=conflict) ──────────────────────────────
_DRIVER_RESOLVED_FILES=""
_MANUAL_FILES=""

_rap_rebase() {
    local behind
    behind="$(git -C "$REPO_ROOT" rev-list --count HEAD.."${FULL_BASE}" 2>/dev/null || echo 0)"
    if [[ "$behind" -eq 0 ]]; then
        info "Already up to date with $FULL_BASE — no rebase needed."
        return 0
    fi
    info "Rebasing $BRANCH onto $FULL_BASE ($behind commit(s) behind) …"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] git rebase ${_rebase_args[*]+"${_rebase_args[*]}"} $FULL_BASE"
        return 0
    fi

    # "${arr[@]+"${arr[@]}"}" is the bash-safe idiom for empty-array expansion
    # under set -u (nounset). Plain "${arr[@]}" fails when arr=() in bash <5.1.
    if ! git -C "$REPO_ROOT" rebase ${_rebase_args[@]+"${_rebase_args[@]}"} "$FULL_BASE"; then
        # Collect conflicted files
        local conflicted
        conflicted="$(git -C "$REPO_ROOT" diff --name-only --diff-filter=U 2>/dev/null || true)"
        local count=0
        [[ -n "$conflicted" ]] && count="$(wc -l <<< "$conflicted" | tr -d ' ')"

        red "Rebase conflict — $count file(s) need manual resolution:"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local lines
            lines="$(wc -l < "$REPO_ROOT/$f" 2>/dev/null || echo '?')"
            red "  $f  (~${lines} lines)"
        done <<< "$conflicted"
        red ""
        red "Manual resolution:"
        red "  1. Edit each file to resolve conflicts"
        red "  2. git add <file>"
        red "  3. git rebase --continue"
        red "  4. Re-run: chump-rebase-and-push.sh"

        git -C "$REPO_ROOT" rebase --abort 2>/dev/null || true
        _MANUAL_FILES="$conflicted"
        return 2
    fi

    # Check for driver-auto-resolved files via git log of the rebase
    _DRIVER_RESOLVED_FILES="$(git -C "$REPO_ROOT" diff --name-only "${FULL_BASE}..HEAD" \
        -- '.github/workflows/ci.yml' 'docs/observability/EVENT_REGISTRY.yaml' \
           'scripts/git-hooks/pre-commit' 'Cargo.toml' 'web/v2/app.js' 'src/main.rs' \
        2>/dev/null | head -20 || true)"
    return 0
}

# ── Step 3: push with force-with-lease ───────────────────────────────────────
_rap_push() {
    info "Pushing $BRANCH to $REMOTE …"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] git push $REMOTE $BRANCH --force-with-lease"
        return 0
    fi
    git -C "$REPO_ROOT" push "$REMOTE" "$BRANCH" --force-with-lease
}

# ── Main: fetch → rebase → push (with one retry on lease rejection) ──────────
RETRIES=0
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

_rap_fetch

_rebase_rc=0
_rap_rebase || _rebase_rc=$?
if [[ "$_rebase_rc" -eq 2 ]]; then
    _emit "rebase_and_push_failed" \
        '"stage":"rebase","manual_files":"'"$(echo "$_MANUAL_FILES" | tr '\n' ',' | sed 's/,$//')"'"'
    exit 2
fi

# INFRA-1526: post-rebase hunk-drop guard (blocks silent data loss before push).
if [[ "$DRY_RUN" == "0" ]] && git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
    if ! BASE_BRANCH="$BASE_REF" bash "$(dirname "${BASH_SOURCE[0]}")/post-rebase-hunk-verify.sh" --emit-ambient; then
        red "INFRA-1526: post-rebase hunk-drop detected — aborting push to prevent silent data loss."
        _emit "rebase_and_push_failed" '"stage":"hunk_verify","reason":"rebase_hunk_dropped"'
        exit 2
    fi
fi

_push_rc=0
if ! _rap_push; then
    _push_rc=$?
    info "force-with-lease rejected — sibling pushed; retrying once (fetch+rebase+push) …"
    RETRIES=1

    _rap_fetch

    _rebase_rc=0
    _rap_rebase || _rebase_rc=$?
    if [[ "$_rebase_rc" -eq 2 ]]; then
        _emit "rebase_and_push_failed" \
            '"stage":"rebase_retry","manual_files":"'"$(echo "$_MANUAL_FILES" | tr '\n' ',' | sed 's/,$//')"'"'
        exit 2
    fi

    if ! _rap_push; then
        red "Push rejected twice. A sibling is actively pushing to the same branch."
        red "Wait 30s, then re-run: chump-rebase-and-push.sh"
        _emit "rebase_and_push_failed" '"stage":"push_retry","retries":1'
        exit 3
    fi
fi

# ── Success ───────────────────────────────────────────────────────────────────
END_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DRIVER_JSON="$(echo "${_DRIVER_RESOLVED_FILES:-}" | tr '\n' ',' | sed 's/,$//' | sed 's/"/\\"/g')"

_emit "rebase_and_push_invoked" \
    "\"start\":\"${START_TS}\",\"end\":\"${END_TS}\",\"retries\":${RETRIES},\"driver_resolved_files\":\"${DRIVER_JSON}\""

grn "✓ $BRANCH rebased on $FULL_BASE and pushed (retries=$RETRIES)"
exit 0
