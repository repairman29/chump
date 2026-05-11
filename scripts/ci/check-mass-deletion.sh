#!/usr/bin/env bash
# check-mass-deletion.sh — CREDIBLE-027: mass-deletion / scratch-commit guard.
#
# Two checks:
#   1. Net deletions: PR diff vs base deletes >100 lines from files whose
#      paths are NOT mentioned in the PR title/body or recent commit messages.
#      Catches accidental mass-wipes (PR #1441: 378k lines gone).
#
#   2. Vague commit titles: any commit whose subject is one of the known
#      scratch-commit patterns ('first', 'init', 'wip', 'unrelated change',
#      'INFRA-X', 'edit gap_store', etc.) is flagged.
#      Catches rogue fixture commits on production branches.
#
# Exit: 0 = clean, 1 = violations found (unless --warn-only).
#
# Usage (local dev):
#   bash scripts/ci/check-mass-deletion.sh [--base <branch>] [--warn-only]
#
# Usage (CI — run from repo root with GITHUB_BASE_REF set):
#   bash scripts/ci/check-mass-deletion.sh

set -euo pipefail

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

WARN_ONLY=0
BASE_BRANCH="${GITHUB_BASE_REF:-main}"
# Parse args without indirect expansion (portable bash 3)
prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --warn-only) WARN_ONLY=1 ;;
        --base|--repo-root) ;;
    esac
    [[ "$prev_arg" == "--base" ]] && BASE_BRANCH="$arg"
    prev_arg="$arg"
done
# Default to pwd (so CI can cd to repo root first, and tests can cd to fixture repo)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

VIOLATIONS=0
report_violation() {
    fail "$1"
    VIOLATIONS=$((VIOLATIONS + 1))
}

# ── Resolve merge base ────────────────────────────────────────────────────────
MERGE_BASE="$(git merge-base HEAD "origin/${BASE_BRANCH}" 2>/dev/null \
    || git merge-base HEAD "${BASE_BRANCH}" 2>/dev/null \
    || git rev-parse "origin/${BASE_BRANCH}" 2>/dev/null \
    || echo "")"
if [[ -z "$MERGE_BASE" ]]; then
    warn "Could not compute merge base against $BASE_BRANCH — skipping checks"
    exit 0
fi
info "Checking diff against merge base $MERGE_BASE (${BASE_BRANCH})"

# ── Check 1: Vague commit titles ─────────────────────────────────────────────
VAGUE_PATTERNS="^(first|init|wip|unrelated change|INFRA-X|edit gap_store|test|fix|asdf|temp|tmp|placeholder)$"
COMMITS_IN_PR="$(git log --pretty=format:%s "${MERGE_BASE}..HEAD" 2>/dev/null || true)"
vague_found=()
while IFS= read -r subject; do
    [[ -z "$subject" ]] && continue
    # Match exact vague titles or subjects that are just "Co-Authored-By" trailers
    lower="$(echo "$subject" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')"
    if echo "$lower" | grep -qE "^(first|init|wip|unrelated change|infra-x|edit gap_store|asdf|temp|tmp|placeholder)$"; then
        vague_found+=("$subject")
    fi
done <<< "$COMMITS_IN_PR"

if [[ ${#vague_found[@]} -gt 0 ]]; then
    for v in "${vague_found[@]}"; do
        report_violation "Vague commit title detected: '$v' — use a descriptive imperative subject"
    done
else
    pass "No vague commit titles"
fi

# ── Check 2: Mass deletions from unrelated files ──────────────────────────────
# Collect PR context: title + body from gh CLI if available, else from commit messages
PR_CONTEXT=""
if command -v gh &>/dev/null; then
    # Try to get PR title + body from the current branch
    PR_INFO="$(gh pr view --json title,body 2>/dev/null || true)"
    if [[ -n "$PR_INFO" ]]; then
        PR_CONTEXT="$(echo "$PR_INFO" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
print((d.get('title','') + ' ' + d.get('body','')).lower())
" 2>/dev/null || true)"
    fi
fi
# Fallback: use commit messages as context
if [[ -z "$PR_CONTEXT" ]]; then
    PR_CONTEXT="$(git log --pretty=format:"%s %b" "${MERGE_BASE}..HEAD" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
fi

# Get all files with their net line-count change (deletions - insertions, per file)
# We flag a file if: net deletions > THRESHOLD and file path not in PR context
THRESHOLD=100
flagged_files=()
total_flagged_deletions=0

while IFS=$'\t' read -r insertions deletions filepath; do
    # Skip binary files and empty entries
    [[ -z "$filepath" || "$insertions" == "-" ]] && continue
    ins="${insertions:-0}"
    del="${deletions:-0}"
    # net deletion = del - ins; only flag when net deletions exceed threshold
    net_del=$(( del - ins ))
    [[ "$net_del" -le "$THRESHOLD" ]] && continue

    # Check if the file path (or its directory stem) appears in PR context
    # Strip path to basename stem and first directory component for matching
    base="$(basename "$filepath" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]')"
    dir1="$(echo "$filepath" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')"
    dir2="$(echo "$filepath" | cut -d/ -f2 | tr '[:upper:]' '[:lower:]')"

    mentioned=0
    for token in "$base" "$dir1" "$dir2"; do
        [[ -z "$token" ]] && continue
        if echo "$PR_CONTEXT" | grep -qF "$token"; then
            mentioned=1
            break
        fi
    done

    if [[ "$mentioned" -eq 0 ]]; then
        flagged_files+=("$filepath (net -${net_del} lines)")
        total_flagged_deletions=$((total_flagged_deletions + net_del))
    fi
done < <(git diff --numstat "${MERGE_BASE}..HEAD" 2>/dev/null || true)

if [[ ${#flagged_files[@]} -gt 0 ]]; then
    report_violation "Mass deletion from files not mentioned in PR title/body (threshold: ${THRESHOLD} lines):"
    for f in "${flagged_files[@]}"; do
        fail "  $f"
    done
    fail "  Total unrelated deletions: $total_flagged_deletions lines"
    fail "  If intentional, mention the affected paths in the PR body."
else
    pass "No mass unrelated deletions (threshold: ${THRESHOLD} lines)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$VIOLATIONS" -eq 0 ]]; then
    echo "CREDIBLE-027: all mass-deletion checks passed."
    exit 0
elif [[ "$WARN_ONLY" -eq 1 ]]; then
    warn "CREDIBLE-027: $VIOLATIONS violation(s) found (warn-only mode — not blocking)"
    exit 0
else
    fail "CREDIBLE-027: $VIOLATIONS violation(s) found. Fix before pushing."
    exit 1
fi
