#!/usr/bin/env bash
#
# bot-merge.sh — Automated ship pipeline for agent branches.
#
# Intended for Claude sessions, Cursor agents, and the autonomy loop. Runs the
# full pre-merge checklist, pushes to origin, and opens (or updates) a GitHub PR.
#
# Usage:
#   scripts/bot-merge.sh [--gap GAP-ID ...] [--stack-on PREV-GAP-ID] [--auto-merge] [--skip-tests] [--dry-run]
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
        --dry-run)     DRY_RUN=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

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

# ── Repo context ──────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

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
    red "Run: scripts/gap-preflight.sh ${GAP_IDS[*]:-<gap-ids>}"
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

# ── 3. cargo clippy ───────────────────────────────────────────────────────────
if command -v cargo &>/dev/null; then
    stage_start "cargo clippy --workspace --all-targets"
    if ! run_timed_hb "cargo clippy" 300 cargo clippy --workspace --all-targets -- -D warnings 2>&1; then
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
        exit 1
    fi
    stage_done
    green "Tests passed."
else
    info "Skipping tests (--skip-tests)."
fi

# ── 5. Push ───────────────────────────────────────────────────────────────────
stage_start "git push $BRANCH → $REMOTE"
if ! run_timed_hb "git push" 120 git push "$REMOTE" "$BRANCH" --force-with-lease; then
    red "git push failed or timed out."
    exit 2
fi
stage_done
green "Pushed."

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
                "3. Once all checks pass, re-run: \`scripts/bot-merge.sh --gap <GAP-ID> --auto-merge\`"
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
