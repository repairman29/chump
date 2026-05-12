#!/usr/bin/env bash
# pr-fmt-shepherd.sh — INFRA-759
#
# Detects open PRs with failing `cargo fmt --check` CI jobs and auto-fixes
# them by running `cargo fmt`, committing, and pushing.
#
# Distinct from pr-watch-shepherd.sh (which handles DIRTY-after-arm rebases).
# This shepherd targets the cargo fmt failure class only — it will NOT
# attempt to fix other CI failure types (lint errors, test failures, etc.).
#
# Usage:
#   pr-fmt-shepherd.sh             # dry-run (no push, no commit)
#   pr-fmt-shepherd.sh --execute   # actually fix + push
#
# Environment:
#   REPO_ROOT          Repository root (default: auto-detected)
#   REMOTE             Git remote (default: origin)
#   PR_FMT_MAX_PRS     Max PRs to inspect per run (default: 30)
#   PR_FMT_COOLDOWN_S  Seconds before retrying same PR head SHA (default: 3600)
#   CHUMP_PR_FMT_SHEPHERD=0   Bypass — exit 0 immediately (for tests)
#
# Emits one `pr_fmt_auto_fixed` event to ambient.jsonl for each fixed PR.
# Emits one `pr_fmt_shepherd_run` summary event at end of each run.

set -uo pipefail

if [[ "${CHUMP_PR_FMT_SHEPHERD:-1}" == "0" ]]; then
    echo "[pr-fmt-shepherd] CHUMP_PR_FMT_SHEPHERD=0 — bypass"
    exit 0
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [[ -z "$REPO_ROOT" ]]; then
    echo "[pr-fmt-shepherd] not in a git checkout — exit 1" >&2
    exit 1
fi
cd "$REPO_ROOT"

COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
if [[ "$COMMON_DIR" == ".git" || "$COMMON_DIR" == "$REPO_ROOT/.git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$COMMON_DIR/.." && pwd)"
fi

if ! command -v gh >/dev/null; then
    echo "[pr-fmt-shepherd] gh CLI not found — exit 1" >&2
    exit 1
fi

REMOTE="${REMOTE:-origin}"
PR_FMT_MAX_PRS="${PR_FMT_MAX_PRS:-30}"
PR_FMT_COOLDOWN_S="${PR_FMT_COOLDOWN_S:-3600}"
EXECUTE=0
[[ "${1:-}" == "--execute" ]] && EXECUTE=1

AMBIENT="$MAIN_REPO/.chump-locks/ambient.jsonl"
COOLDOWN_DIR="/tmp/chump-pr-fmt-cooldown"
mkdir -p "$COOLDOWN_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit_ambient() {
    local json="$1"
    [[ -d "$(dirname "$AMBIENT")" ]] || return 0
    printf '%s\n' "$json" >> "$AMBIENT"
}

echo "[pr-fmt-shepherd] scanning open PRs for cargo fmt failures (execute=$EXECUTE, max=$PR_FMT_MAX_PRS)"

# Fetch open PRs with their head SHA.
OPEN_PRS=$(gh pr list --state open --limit "$PR_FMT_MAX_PRS" \
    --json number,headRefName,headRefOid \
    --jq '.[] | [.number|tostring, .headRefName, .headRefOid] | join("|")' \
    2>/dev/null || true)

if [[ -z "$OPEN_PRS" ]]; then
    echo "[pr-fmt-shepherd] no open PRs found"
    emit_ambient "{\"ts\":\"$(ts)\",\"kind\":\"pr_fmt_shepherd_run\",\"scanned\":0,\"fixed\":0,\"skipped\":0,\"status\":\"ok\"}"
    exit 0
fi

SCANNED=0
FIXED=0
SKIPPED=0
ERRORS=0

while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r PR BRANCH HEAD_SHA <<< "$entry"
    HEAD_SHA_SHORT="${HEAD_SHA:0:12}"
    SCANNED=$((SCANNED + 1))

    # Cooldown: skip if we already tried this head SHA recently.
    cooldown_marker="$COOLDOWN_DIR/${PR}-${HEAD_SHA_SHORT}"
    if [[ -f "$cooldown_marker" ]]; then
        marker_age=$(( $(date +%s) - $(stat -f %m "$cooldown_marker" 2>/dev/null || stat -c %Y "$cooldown_marker" 2>/dev/null || echo 0) ))
        if (( marker_age < PR_FMT_COOLDOWN_S )); then
            echo "[pr-fmt-shepherd] PR #$PR: cooldown (${marker_age}s < ${PR_FMT_COOLDOWN_S}s)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        rm -f "$cooldown_marker"
    fi

    # Check if this PR has a failing cargo fmt check.
    # We look for a check named matching fmt/format with conclusion=failure.
    FMT_FAILING=$(gh pr checks "$PR" --json name,conclusion \
        --jq '.[] | select(.conclusion == "failure") | .name | select(test("fmt|format"; "i"))' \
        2>/dev/null | head -1 || true)

    if [[ -z "$FMT_FAILING" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "[pr-fmt-shepherd] PR #$PR ($BRANCH): fmt failure detected ($FMT_FAILING)"

    if [[ $EXECUTE -eq 0 ]]; then
        echo "[pr-fmt-shepherd] [dry-run] would run cargo fmt + push on PR #$PR"
        FIXED=$((FIXED + 1))
        continue
    fi

    # Create ephemeral worktree and fix the formatting.
    WT="/tmp/chump-pr-fmt-pr${PR}-$$"
    if ! git fetch "$REMOTE" "$BRANCH" --quiet 2>/dev/null; then
        echo "[pr-fmt-shepherd] PR #$PR: fetch failed — skip" >&2
        ERRORS=$((ERRORS + 1))
        : > "$cooldown_marker"
        continue
    fi

    if ! git worktree add -B "tmp-fmt-pr$PR" "$WT" "$REMOTE/$BRANCH" >/dev/null 2>&1; then
        echo "[pr-fmt-shepherd] PR #$PR: worktree add failed — skip" >&2
        ERRORS=$((ERRORS + 1))
        : > "$cooldown_marker"
        continue
    fi

    pushd "$WT" >/dev/null
    FIX_OK=0
    COMMIT_SHA=""

    if cargo fmt --all 2>/dev/null; then
        # Only commit if there are actual formatting changes.
        if ! git diff --quiet; then
            git add -u
            COMMIT_MSG="chore: auto-fix cargo fmt (pr-fmt-shepherd INFRA-759)"
            if git commit -m "$COMMIT_MSG" --no-verify >/dev/null 2>&1; then
                COMMIT_SHA=$(git rev-parse HEAD)
                if git push "$REMOTE" "$BRANCH" --force-with-lease >/dev/null 2>&1; then
                    FIX_OK=1
                    echo "[pr-fmt-shepherd] PR #$PR: fmt fixed + pushed (sha=${COMMIT_SHA:0:12})"
                else
                    echo "[pr-fmt-shepherd] PR #$PR: push failed" >&2
                fi
            fi
        else
            echo "[pr-fmt-shepherd] PR #$PR: cargo fmt ran but no changes — CI may be testing wrong commit"
        fi
    fi

    popd >/dev/null
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git branch -D "tmp-fmt-pr$PR" >/dev/null 2>&1 || true

    if [[ $FIX_OK -eq 1 ]]; then
        FIXED=$((FIXED + 1))
        emit_ambient "{\"ts\":\"$(ts)\",\"kind\":\"pr_fmt_auto_fixed\",\"pr\":$PR,\"branch\":\"$BRANCH\",\"commit_sha\":\"$COMMIT_SHA\"}"
    else
        ERRORS=$((ERRORS + 1))
        : > "$cooldown_marker"
    fi

done <<< "$OPEN_PRS"

echo "[pr-fmt-shepherd] done: scanned=$SCANNED fixed=$FIXED skipped=$SKIPPED errors=$ERRORS"
emit_ambient "{\"ts\":\"$(ts)\",\"kind\":\"pr_fmt_shepherd_run\",\"scanned\":$SCANNED,\"fixed\":$FIXED,\"skipped\":$SKIPPED,\"errors\":$ERRORS,\"status\":\"ok\"}"
