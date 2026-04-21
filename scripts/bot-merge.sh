#!/usr/bin/env bash
#
# bot-merge.sh — Automated ship pipeline for agent branches.
#
# Intended for Claude sessions, Cursor agents, and the autonomy loop. Runs the
# full pre-merge checklist, pushes to origin, and opens (or updates) a GitHub PR.
#
# Usage:
#   scripts/bot-merge.sh [--gap GAP-ID ...] [--auto-merge] [--skip-tests] [--dry-run]
#
#   --gap GAP-ID   One or more gap IDs to check against origin/main before proceeding.
#                  If any gap is already `done` or claimed by another agent, the
#                  script aborts early. Repeat for multiple gaps: --gap A --gap B
#                  or pass space-separated: --gap "AUTO-003 COMP-002".
#   --auto-merge   Enable GitHub auto-merge on the PR (requires branch protection
#                  with required CI status checks configured).
#   --skip-tests   Skip `cargo test` (for pure-doc or non-Rust changes). fmt and
#                  clippy still run.
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

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_MERGE=0
SKIP_TESTS=0
DRY_RUN=0
GAP_IDS=()
NEXT_IS_GAP=0
for arg in "$@"; do
    if [[ $NEXT_IS_GAP -eq 1 ]]; then
        # Support --gap "AUTO-003 COMP-002" (space-separated) or --gap AUTO-003 --gap COMP-002
        for gid in $arg; do GAP_IDS+=("$gid"); done
        NEXT_IS_GAP=0
        continue
    fi
    case "$arg" in
        --gap)         NEXT_IS_GAP=1 ;;
        --auto-merge)  AUTO_MERGE=1 ;;
        --skip-tests)  SKIP_TESTS=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] $*"
        return 0
    fi
    "$@"
}

# ── Repo context ──────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ── Session-ID auto-detection ─────────────────────────────────────────────────
# gap-preflight reads CHUMP_SESSION_ID to distinguish "our" claim from others'.
# If not set, try to infer it from an existing gap lease file so the preflight
# recognises our own claim at ship time (the claim may have been written by a
# different shell with a different default session ID — e.g. CHUMP_SESSION_ID
# set explicitly during gap-claim.sh vs. ~/.chump/session_id at bot-merge time).
if [[ -z "${CHUMP_SESSION_ID:-}" && ${#GAP_IDS[@]} -gt 0 ]]; then
    LOCK_DIR="$REPO_ROOT/.chump-locks"
    for _gid in "${GAP_IDS[@]}"; do
        for _lf in "$LOCK_DIR"/*.json; do
            [[ -f "$_lf" ]] || continue
            _gap_in_file=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('gap_id', ''))
except Exception:
    print('')
" "$_lf" 2>/dev/null || true)
            if [[ "$_gap_in_file" == "$_gid" ]]; then
                _sid=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('session_id', ''))
except Exception:
    print('')
" "$_lf" 2>/dev/null || true)
                if [[ -n "$_sid" ]]; then
                    export CHUMP_SESSION_ID="$_sid"
                    info "Auto-detected session ID from gap lease: $CHUMP_SESSION_ID"
                    break 2
                fi
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
info "Fetching $REMOTE/$BASE_BRANCH …"
run git fetch "$REMOTE" "$BASE_BRANCH" --quiet

BEHIND=$(git rev-list --count "HEAD..${REMOTE}/${BASE_BRANCH}" 2>/dev/null || echo 0)

# Hard abort if branch is extremely stale — rebase at 40+ commits is risky and
# likely means the work has already landed on main via another agent.
if [[ "$BEHIND" -gt 40 ]]; then
    red "Branch is $BEHIND commits behind $REMOTE/$BASE_BRANCH — too stale to merge safely."
    red "Run: scripts/gap-preflight.sh ${GAP_IDS[*]:-<gap-ids>}"
    red "Then: git fetch && git rebase $REMOTE/$BASE_BRANCH (resolve conflicts)"
    red "If all your gaps are already done on main, close this branch instead."
    exit 3
fi

if [[ "$BEHIND" -gt 0 ]]; then
    info "Branch is $BEHIND commit(s) behind $REMOTE/$BASE_BRANCH — rebasing …"
    run git rebase "${REMOTE}/${BASE_BRANCH}"
    green "Rebase complete."

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
    info "Running cargo fmt …"
    run cargo fmt --all
    if [[ $DRY_RUN -eq 0 ]] && ! git diff --quiet; then
        info "cargo fmt changed files — staging and amending …"
        git add -u
        git commit --amend --no-edit --no-verify
        green "fmt fixes committed."
    fi
fi

# ── 3. cargo clippy ───────────────────────────────────────────────────────────
if command -v cargo &>/dev/null; then
    info "Running cargo clippy …"
    if ! run cargo clippy --workspace --all-targets -- -D warnings 2>&1; then
        red "clippy found errors — fix them before merging."
        exit 1
    fi
    green "clippy clean."
fi

# ── 4. cargo test ─────────────────────────────────────────────────────────────
if [[ $SKIP_TESTS -eq 0 ]] && command -v cargo &>/dev/null; then
    info "Running cargo test --workspace …"
    if ! run cargo test --workspace 2>&1; then
        red "Tests failed — fix them before merging."
        exit 1
    fi
    green "Tests passed."
else
    info "Skipping tests (--skip-tests)."
fi

# ── 5. Push ───────────────────────────────────────────────────────────────────
info "Pushing $BRANCH to $REMOTE …"
run git push "$REMOTE" "$BRANCH" --force-with-lease
green "Pushed."

# ── 6. Open or update PR ─────────────────────────────────────────────────────
EXISTING_PR=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")

if [[ -z "$EXISTING_PR" ]]; then
    info "Creating PR …"
    # Build a body from the gap IDs cited in commits since base diverged.
    COMMIT_LOG=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline 2>/dev/null | head -20)
    GAP_IDS=$(echo "$COMMIT_LOG" | grep -oE '[A-Z]+-[0-9]+' | sort -u | tr '\n' ' ' || true)
    GAP_LINE=""
    [[ -n "$GAP_IDS" ]] && GAP_LINE="**Gaps addressed:** $GAP_IDS"

    PR_TITLE=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | tail -1 | sed 's/^[a-f0-9]* //')

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] gh pr create --base $BASE_BRANCH --title \"$PR_TITLE\" …"
    else
        gh pr create \
            --base "$BASE_BRANCH" \
            --title "$PR_TITLE" \
            --body "$(cat <<EOF
## Changes
$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | sed 's/^/- /')

${GAP_LINE}

## Checklist
- [x] \`cargo fmt\` clean
- [x] \`cargo clippy\` clean
$([ $SKIP_TESTS -eq 0 ] && echo "- [x] \`cargo test\` passed" || echo "- [ ] tests skipped (non-Rust change)")

🤖 Opened by bot-merge.sh
EOF
)"
        green "PR created."
    fi
else
    green "PR #$EXISTING_PR already exists — updated by push."
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
                run git tag "${CHECKPOINT_TAG}" HEAD
                run git push origin "${CHECKPOINT_TAG}"
                green "Checkpoint tag pushed — recovery via 'git checkout ${CHECKPOINT_TAG}'."
            else
                info "Checkpoint tag ${CHECKPOINT_TAG} already exists — skipping."
            fi
        fi

        info "Enabling squash auto-merge on PR #$TARGET_PR …"
        run gh pr merge "$TARGET_PR" --auto --squash
        green "Auto-merge enabled — PR will land when CI passes."
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
