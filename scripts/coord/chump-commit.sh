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
#   scripts/coord/chump-commit.sh <file1> [file2 ...] -m "message"
#   scripts/coord/chump-commit.sh <file1> [file2 ...] -F <msg-file>
#
# The `--` separator is optional; all paths before -m/-F/-F are the
# files to commit. Everything after -m/-F is passed through to git commit.
#
# Example:
#   scripts/coord/chump-commit.sh src/foo.rs docs/bar.md -m "feat(bar): ..."
#
# Environment:
#   CHUMP_ALLOW_MAIN_WORKTREE=1  suppress the "you're in the main worktree"
#                                warning. Recommended for CI and one-off
#                                scripts; bot sessions should get their
#                                own `.claude/worktrees/<name>/` instead.

set -euo pipefail

# ── Escalation mode (INFRA-AGENT-ESCALATION) ─────────────────────────────────
# When called with --escalate "reason", emit an ALERT kind=escalation event to
# .chump-locks/ambient.jsonl and exit 0. This path skips all commit logic and
# is intended for agents that are stuck and need operator attention.
#
# Usage:
#   scripts/coord/chump-commit.sh --escalate "cargo check fails: error[E0499]" \
#       --gap INFRA-FOO-001 \
#       [--agent-id <id>] \
#       [--suggested-action "human review needed"]
if [[ "${1:-}" == "--escalate" ]]; then
    shift
    ESCALATE_REASON="${1:-unspecified}"
    shift || true

    # Optional keyword args after the reason.
    ESCALATE_GAP=""
    ESCALATE_AGENT_ID=""
    ESCALATE_SUGGESTED_ACTION="human review needed"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gap)        shift; ESCALATE_GAP="$1"        ;;
            --agent-id)   shift; ESCALATE_AGENT_ID="$1"   ;;
            --suggested-action) shift; ESCALATE_SUGGESTED_ACTION="$1" ;;
            *) ;;
        esac
        shift || true
    done

    # Resolve repo root and ambient path.
    _ESC_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _ESC_LOCK_DIR="$_ESC_REPO_ROOT/.chump-locks"
    _ESC_AMBIENT="$_ESC_LOCK_DIR/ambient.jsonl"
    mkdir -p "$_ESC_LOCK_DIR"

    # Resolve session ID (same precedence as gap-claim.sh).
    _ESC_SESSION="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    if [[ -z "$_ESC_SESSION" ]]; then
        _ESC_WT_CACHE="$_ESC_LOCK_DIR/.wt-session-id"
        [[ -f "$_ESC_WT_CACHE" ]] && _ESC_SESSION="$(cat "$_ESC_WT_CACHE" 2>/dev/null || true)"
    fi
    if [[ -z "$_ESC_SESSION" && -f "$HOME/.chump/session_id" ]]; then
        _ESC_SESSION="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
    fi
    _ESC_SESSION="${_ESC_SESSION:-escalate-$$-$(date +%s)}"

    _ESC_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Build JSON and append to ambient.jsonl.
    _ESC_JSON="$(python3 -c "
import json, sys
d = {
    'ts':               sys.argv[1],
    'session':          sys.argv[2],
    'event':            'ALERT',
    'kind':             'escalation',
    'gap_id':           sys.argv[3],
    'agent_id':         sys.argv[4],
    'stuck_at':         sys.argv[5],
    'last_error':       sys.argv[5],
    'suggested_action': sys.argv[6],
}
print(json.dumps(d))
" "$_ESC_TS" "$_ESC_SESSION" "${ESCALATE_GAP:-}" "${ESCALATE_AGENT_ID:-$_ESC_SESSION}" "$ESCALATE_REASON" "$ESCALATE_SUGGESTED_ACTION")"

    # Try ambient-emit.sh if available, otherwise direct append.
    _ESC_EMIT="$_ESC_REPO_ROOT/scripts/dev/ambient-emit.sh"
    if [[ -x "$_ESC_EMIT" ]]; then
        printf '%s\n' "$_ESC_JSON" | "$_ESC_EMIT" 2>/dev/null || printf '%s\n' "$_ESC_JSON" >> "$_ESC_AMBIENT"
    else
        _ESC_TMP="$(mktemp "$_ESC_LOCK_DIR/.escalate_XXXXXX")"
        printf '%s\n' "$_ESC_JSON" >> "$_ESC_TMP"
        cat "$_ESC_TMP" >> "$_ESC_AMBIENT"
        rm -f "$_ESC_TMP"
    fi

    echo "[chump-commit] ESCALATION emitted to ambient.jsonl" >&2
    printf '[broadcast] ALERT   kind=escalation  gap=%s  reason=%s\n' "${ESCALATE_GAP:-}" "$ESCALATE_REASON"
    exit 0
fi

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
    echo "[chump-commit] Bypass (dangerous): CHUMP_POST_SHIP_COMMIT=1 scripts/coord/chump-commit.sh ..." >&2
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

# ── Ambient glance (INFRA-083) ───────────────────────────────────────────────
# Before locking in the commit, scan ambient.jsonl for sibling sessions that
# recently edited any of the staged paths. Advisory only here (the pre-commit
# hook's lease-collision guard is the hard gate); this surfaces near-misses
# the lease layer can't see (e.g. a sibling without a path-lease).
SCRIPT_DIR_GLANCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR_GLANCE/chump-ambient-glance.sh" ]] && [[ "${CHUMP_AMBIENT_GLANCE:-1}" != "0" ]]; then
    _STAGED_CSV="$(IFS=,; printf '%s' "${FILES[*]}")"
    "$SCRIPT_DIR_GLANCE/chump-ambient-glance.sh" --paths "$_STAGED_CSV" --since-secs 600 --limit 5 || true
fi

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

# ── Path-lease conflict advisory (INFRA-FILE-LEASE) ──────────────────────────
# Check staged files against ALL active lease files in .chump-locks/. If a
# staged file appears in another session's `paths` list, print a CONFLICT
# warning. Advisory only — does not block the commit — so agents can still
# ship when they're certain the overlap is safe.
#
# Bypass: CHUMP_LEASE_CHECK=0
if [[ "${CHUMP_LEASE_CHECK:-1}" != "0" ]]; then
    LOCKS_DIR="$REPO_ROOT/.chump-locks"
    if [[ -d "$LOCKS_DIR" ]]; then
        # Resolve my session ID (same priority order as gap-claim.sh).
        _MY_SID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
        if [[ -z "$_MY_SID" ]]; then
            _WT_CACHE="$LOCKS_DIR/.wt-session-id"
            [[ -f "$_WT_CACHE" ]] && _MY_SID="$(cat "$_WT_CACHE")"
        fi
        if [[ -z "$_MY_SID" ]] && [[ -f "$HOME/.chump/session_id" ]]; then
            _MY_SID="$(head -n1 "$HOME/.chump/session_id" 2>/dev/null | tr -d '[:space:]')"
        fi

        if [[ -n "$_MY_SID" ]]; then
            _STAGED_FILES="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
            if [[ -n "$_STAGED_FILES" ]]; then
                _now_epoch="$(date -u +%s)"
                _path_conflicts=""

                for _lease in "$LOCKS_DIR"/*.json; do
                    [[ -f "$_lease" ]] || continue

                    _holder="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_lease" | head -n1)"
                    [[ -n "$_holder" ]] || continue
                    [[ "$_holder" = "$_MY_SID" ]] && continue

                    # Skip expired leases.
                    _expires="$(sed -n 's/.*"expires_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_lease" | head -n1)"
                    _exp_epoch=""
                    if [[ -n "$_expires" ]]; then
                        if [[ "$(uname -s)" = "Darwin" ]]; then
                            _exp_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_expires" +%s 2>/dev/null || true)"
                        else
                            _exp_epoch="$(date -u -d "$_expires" +%s 2>/dev/null || true)"
                        fi
                    fi
                    if [[ -n "$_exp_epoch" ]] && [[ "$_exp_epoch" -le "$_now_epoch" ]]; then
                        continue
                    fi

                    # Extract paths[] from lease JSON (handles pretty-printed and compact).
                    _lease_paths="$(awk '
                        /"paths"[[:space:]]*:/ { flag=1 }
                        flag            { print }
                        flag && /\]/    { flag=0 }
                    ' "$_lease" \
                        | grep -oE '"[^"]+"' \
                        | sed 's/^"//;s/"$//' \
                        | grep -vx 'paths' || true)"

                    [[ -n "$_lease_paths" ]] || continue

                    # Check each lease path against staged files.
                    while IFS= read -r _lpat; do
                        [[ -n "$_lpat" ]] || continue
                        while IFS= read -r _staged; do
                            [[ -n "$_staged" ]] || continue
                            # Exact match or prefix match (foo/bar/ prefix).
                            _matched=0
                            if [[ "$_lpat" = "$_staged" ]]; then
                                _matched=1
                            elif [[ "${_lpat%/}" != "$_lpat" ]]; then
                                # Trailing slash → prefix match.
                                case "$_staged" in
                                    "${_lpat}"*) _matched=1 ;;
                                esac
                            elif [[ "${_lpat%/\*\*}" != "$_lpat" ]]; then
                                # foo/bar/** → prefix match on foo/bar/.
                                _pfx="${_lpat%/\*\*}/"
                                case "$_staged" in
                                    "${_pfx}"*) _matched=1 ;;
                                esac
                            fi
                            if [[ "$_matched" = "1" ]]; then
                                _path_conflicts="${_path_conflicts}  ${_staged}  (claimed by session ${_holder} in $(basename "$_lease"))\n"
                            fi
                        done <<< "$_STAGED_FILES"
                    done <<< "$_lease_paths"
                done

                if [[ -n "$_path_conflicts" ]]; then
                    echo "[chump-commit] PATH-LEASE CONFLICT (advisory) — staged file(s) claimed by another session:" >&2
                    printf '%b' "$_path_conflicts" >&2
                    echo "[chump-commit]" >&2
                    echo "[chump-commit] This is advisory — the commit is NOT blocked. Proceed if you are certain" >&2
                    echo "[chump-commit] the overlap is safe, or coordinate with the other session first." >&2
                    echo "[chump-commit] To silence: CHUMP_LEASE_CHECK=0 scripts/coord/chump-commit.sh ..." >&2
                fi
            fi
        fi
    fi
fi

# Commit with the passed-through git args.
exec git commit "${GIT_ARGS[@]}"
