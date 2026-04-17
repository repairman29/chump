#!/usr/bin/env bash
#
# bot-merge.sh — Automated ship pipeline for agent branches.
#
# Intended for Claude sessions, Cursor agents, and the autonomy loop. Runs the
# full pre-merge checklist, pushes to origin, and opens (or updates) a GitHub PR.
#
# Usage:
#   scripts/bot-merge.sh [--auto-merge] [--skip-tests] [--dry-run]
#
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
#   1  Pre-flight check failed (fmt, clippy, tests)
#   2  Push or gh command failed

set -euo pipefail

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_MERGE=0
SKIP_TESTS=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
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

# ── 1. Fetch and rebase ───────────────────────────────────────────────────────
info "Fetching $REMOTE/$BASE_BRANCH …"
run git fetch "$REMOTE" "$BASE_BRANCH" --quiet

BEHIND=$(git rev-list --count "HEAD..${REMOTE}/${BASE_BRANCH}" 2>/dev/null || echo 0)
if [[ "$BEHIND" -gt 0 ]]; then
    info "Branch is $BEHIND commit(s) behind $REMOTE/$BASE_BRANCH — rebasing …"
    run git rebase "${REMOTE}/${BASE_BRANCH}"
    green "Rebase complete."
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
        info "Enabling squash auto-merge on PR #$TARGET_PR …"
        run gh pr merge "$TARGET_PR" --auto --squash
        green "Auto-merge enabled — PR will land when CI passes."
    fi
fi

green "=== bot-merge done. ==="
