#!/usr/bin/env bash
# chump-commit.sh — explicit-file commit wrapper.
#
# Purpose: stop the "pre-staged WIP from another agent leaks into my commit"
# stomp that shared worktrees produce. Standard `git add foo.rs && git
# commit` includes ANYTHING already staged by any other session. This
# wrapper reset-staged-everything, stages ONLY the files you name, then
# commits — so another agent's in-flight `git add` can't ride along.
#
# Usage:
#   scripts/chump-commit.sh <file1> [file2 ...] -m "message"
#   scripts/chump-commit.sh <file1> [file2 ...] -F <msg-file>
#
# The `--` separator is optional; all paths before -m/-F/-F are the
# files to commit. Everything after -m/-F is passed through to git commit.
#
# Example:
#   scripts/chump-commit.sh src/foo.rs docs/bar.md -m "feat(bar): ..."
#
# Environment:
#   CHUMP_ALLOW_MAIN_WORKTREE=1  suppress the "you're in the main worktree"
#                                warning. Recommended for CI and one-off
#                                scripts; bot sessions should get their
#                                own `.claude/worktrees/<name>/` instead.

set -euo pipefail

# ── Post-ship guard (INFRA-BOT-MERGE-LOCK) ───────────────────────────────────
# bot-merge.sh writes .bot-merge-shipped on successful PR ship to enforce the
# "PR frozen once shipped" rule (PR #52 retrospective). Any further commits
# would be dropped by GitHub's squash-merge, repeating the same data-loss.
# Bypass only when you genuinely need to e.g. fix a CI script in-place and
# know what you are doing — not for "just one more small thing".
_repo_root_early="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$_repo_root_early" && -f "$_repo_root_early/.bot-merge-shipped" ]] \
   && [[ "${CHUMP_POST_SHIP_COMMIT:-0}" != "1" ]]; then
    echo "[chump-commit] ERROR: This worktree has already been shipped." >&2
    echo "[chump-commit]   $(cat "$_repo_root_early/.bot-merge-shipped")" >&2
    echo "" >&2
    echo "[chump-commit] Do NOT push more commits to an in-flight PR — they will be" >&2
    echo "[chump-commit] silently dropped by GitHub squash-merge (see PR #52 post-mortem)." >&2
    echo "" >&2
    echo "[chump-commit] To do more work: open a new worktree for a new gap." >&2
    echo "[chump-commit]   git worktree add .claude/worktrees/<new-name> -b claude/<new-name>" >&2
    echo "" >&2
    echo "[chump-commit] Bypass (dangerous): CHUMP_POST_SHIP_COMMIT=1 scripts/chump-commit.sh ..." >&2
    exit 1
fi

if [[ $# -lt 2 ]]; then
  sed -n '2,25p' "$0"
  exit 2
fi

# Split args into files and git-commit passthroughs.
FILES=()
GIT_ARGS=()
SEEN_DIVIDER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|-F|--message|--file|-C|--reedit-message|--reuse-message|--amend|--signoff|-s|--no-edit|--allow-empty|--allow-empty-message|-n|--no-verify)
      SEEN_DIVIDER=1
      GIT_ARGS+=("$1")
      if [[ "$1" == "-m" || "$1" == "-F" || "$1" == "--message" || "$1" == "--file" || "$1" == "-C" ]]; then
        shift
        GIT_ARGS+=("$1")
      fi
      ;;
    --)
      SEEN_DIVIDER=1
      ;;
    *)
      if [[ $SEEN_DIVIDER -eq 0 ]]; then
        FILES+=("$1")
      else
        GIT_ARGS+=("$1")
      fi
      ;;
  esac
  shift || true
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: no files given before -m/-F" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
cd "$REPO_ROOT"

# Warn (non-blocking) when operating in the main checkout. Separate
# worktrees are the long-term fix for the shared-worktree stomp class.
MAIN_WORKTREE="/Users/jeffadkins/Projects/Chump"
if [[ "$REPO_ROOT" == "$MAIN_WORKTREE" && -z "${CHUMP_ALLOW_MAIN_WORKTREE:-}" ]]; then
  echo "[chump-commit] WARNING: operating in the main worktree ($REPO_ROOT)." >&2
  echo "[chump-commit] Consider using .claude/worktrees/<name>/ for bot sessions." >&2
  echo "[chump-commit] Suppress this warning: CHUMP_ALLOW_MAIN_WORKTREE=1" >&2
fi

# Verify every file the user named actually exists OR is a deletion.
for f in "${FILES[@]}"; do
  if [[ ! -e "$f" ]]; then
    # Might be a staged deletion; check git.
    if ! git ls-files --deleted --modified --others --cached -- "$f" | grep -q .; then
      echo "ERROR: $f not found and not in git index" >&2
      exit 2
    fi
  fi
done

# If there's a current index that doesn't match the files we want, reset it
# all first. Preserves working-tree changes — only touches the index.
# Using a while-read loop rather than `mapfile` because macOS ships bash 3.2
# which predates the builtin.
STAGED_BEFORE=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -n "$STAGED_BEFORE" ]]; then
  EXTRA=()
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    keep=0
    for w in "${FILES[@]}"; do
      if [[ "$h" == "$w" ]]; then keep=1; break; fi
    done
    [[ $keep -eq 0 ]] && EXTRA+=("$h")
  done <<< "$STAGED_BEFORE"
  if [[ ${#EXTRA[@]} -gt 0 ]]; then
    echo "[chump-commit] Un-staging files you didn't ask to commit:" >&2
    for e in "${EXTRA[@]}"; do echo "  - $e" >&2; done
    git reset HEAD -- "${EXTRA[@]}" >/dev/null
  fi
fi

# Stage exactly the files the user named.
git add -- "${FILES[@]}"

# Wrong-worktree guard (2026-04-18 incident): if NONE of the named files
# actually have changes in this worktree (staged or unstaged), the commit
# will be empty — usually because the user's edits landed in a DIFFERENT
# worktree (typical when a python script with absolute paths writes to
# /Users/jeffadkins/Projects/Chump while the user is in a worktree).
# Detect by re-checking after the add: if the index is unchanged from
# HEAD on every named file, something's off.
if [[ "${CHUMP_WRONG_WORKTREE_CHECK:-1}" != "0" ]]; then
  any_changed=0
  for f in "${FILES[@]}"; do
    if ! git diff --cached --quiet -- "$f" 2>/dev/null; then
      any_changed=1
      break
    fi
  done
  if [[ $any_changed -eq 0 ]]; then
    echo "[chump-commit] WARNING: none of the named files have any changes in this worktree." >&2
    echo "[chump-commit]   pwd: $(pwd)" >&2
    # Look for the same paths in other worktrees that DO have changes.
    while IFS= read -r wt; do
      [[ -z "$wt" ]] && continue
      [[ "$wt" == "$REPO_ROOT" ]] && continue
      [[ ! -d "$wt" ]] && continue
      for f in "${FILES[@]}"; do
        if [[ -f "$wt/$f" ]] && (cd "$wt" && ! git diff --quiet -- "$f" 2>/dev/null); then
          echo "[chump-commit]   ⚠️  found unstaged changes for $f in: $wt" >&2
          echo "[chump-commit]      → run from that worktree, or copy the file in." >&2
        fi
      done
    done < <(git worktree list --porcelain | awk '/^worktree / { print $2 }')
    echo "[chump-commit] Bypass: CHUMP_WRONG_WORKTREE_CHECK=0 git commit ..." >&2
    exit 1
  fi
fi

# Commit with the passed-through git args.
exec git commit "${GIT_ARGS[@]}"
