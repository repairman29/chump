#!/usr/bin/env bash
# install-git-stash-trace.sh — META-016 — install the git wrapper that traces stash invocations
#
# Idempotent. Safe to re-run. Verifies pre-conditions (PATH ordering,
# wrapper executable) and prints next-step instructions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/dev/git-stash-trace-wrapper.sh"
INSTALL_PATH="${CHUMP_STASH_TRACE_INSTALL_PATH:-$HOME/.local/bin/git}"

if [ ! -x "$WRAPPER" ]; then
  echo "ERROR: wrapper not found or not executable at $WRAPPER" >&2
  exit 1
fi

# Ensure ~/.local/bin precedes /usr/bin in PATH; otherwise the wrapper is
# bypassed and we waste time.
local_bin_dir="$(dirname "$INSTALL_PATH")"
case ":$PATH:" in
  *":$local_bin_dir:"*)
    # OK — but verify it's BEFORE /usr/bin
    local_pos=$(echo "$PATH" | tr ':' '\n' | awk -v d="$local_bin_dir" '$0 == d {print NR; exit}')
    usr_pos=$(echo "$PATH" | tr ':' '\n' | awk '$0 == "/usr/bin" {print NR; exit}')
    if [ -n "$local_pos" ] && [ -n "$usr_pos" ] && [ "$local_pos" -gt "$usr_pos" ]; then
      echo "WARNING: $local_bin_dir is in PATH but AFTER /usr/bin (positions $local_pos vs $usr_pos)." >&2
      echo "  The wrapper will be bypassed. Edit shell rc to put $local_bin_dir first." >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: $local_bin_dir is not in PATH; add it before /usr/bin and re-run" >&2
    exit 1
    ;;
esac

mkdir -p "$local_bin_dir"

# If a wrapper is already installed, check whether it's ours or a foreign one.
if [ -e "$INSTALL_PATH" ] || [ -L "$INSTALL_PATH" ]; then
  if [ -L "$INSTALL_PATH" ]; then
    target=$(readlink "$INSTALL_PATH")
    if [ "$target" = "$WRAPPER" ]; then
      echo "OK: already installed (symlink $INSTALL_PATH → $WRAPPER)"
      echo
      echo "Next: any \`git stash …\` invocation will be logged to:"
      echo "  ${CHUMP_STASH_TRACE_LOG:-$HOME/.claude/projects/-Users-jeffadkins-Projects-Chump/notes/git-stash-trace.log}"
      echo
      echo "Inspect matches: $REPO_ROOT/scripts/dev/find-stash-creator.sh"
      exit 0
    else
      echo "ERROR: $INSTALL_PATH already exists and points at $target (not our wrapper)" >&2
      echo "  Move/remove it manually before re-running this installer." >&2
      exit 1
    fi
  else
    echo "ERROR: $INSTALL_PATH already exists as a non-symlink. Move/remove it manually." >&2
    exit 1
  fi
fi

ln -s "$WRAPPER" "$INSTALL_PATH"

echo "installed: $INSTALL_PATH → $WRAPPER"
echo
echo "Verifying wrapper is reachable first…"
hash -r 2>/dev/null || true
which_git=$(which git 2>/dev/null || echo "(none)")
if [ "$which_git" != "$INSTALL_PATH" ]; then
  echo "WARNING: \`which git\` returns $which_git, not $INSTALL_PATH." >&2
  echo "  Run \`hash -r\` (bash) / \`rehash\` (zsh) in your shell, or open a new shell." >&2
  exit 1
fi

echo "OK: which git = $which_git"
echo
echo "Smoke test (this should pass through to /usr/bin/git unchanged):"
"$INSTALL_PATH" --version || { echo "FAIL: wrapper broke pass-through" >&2; exit 1; }
echo
echo "Done. Stash invocations are now logged to:"
echo "  ${CHUMP_STASH_TRACE_LOG:-$HOME/.claude/projects/-Users-jeffadkins-Projects-Chump/notes/git-stash-trace.log}"
echo
echo "When the next claude-*-stash event fires, run:"
echo "  $REPO_ROOT/scripts/dev/find-stash-creator.sh"
echo
echo "Uninstall: rm $INSTALL_PATH"
