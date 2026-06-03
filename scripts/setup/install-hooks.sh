#!/usr/bin/env bash
#
# One-shot installer for Chump's git hooks. Installs into every git worktree
# (main + linked) so parallel agents in `.claude/worktrees/` are protected
# from cargo-fmt drift even when their working-tree branch doesn't have the
# hook source file checked out.
#
# Why per-worktree (not core.hooksPath): linked git worktrees have their own
# `.git/worktrees/<name>/hooks/` dir. core.hooksPath is shared across
# worktrees but resolved against the WORKING tree, so worktrees on stale
# branches that don't have scripts/git-hooks/ checked out would see no hooks.
# Per-worktree symlinks pointing at an absolute path Just Work everywhere.
#
# Run once after cloning. Idempotent — safe to re-run any time, especially
# after `git worktree add`.

set -euo pipefail

# --quiet suppresses per-worktree install lines; errors still go to stderr.
# --profile <name>  selects the hook profile written to each worktree's
#   .git/chump-hook-profile. Profiles: chump (default, all guards),
#   chump-proprietary (gap-id + fmt/check/clippy + credential; no research
#   guards), external-minimal (gap-id + fmt/check only).
QUIET=0
PROFILE="chump"
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) QUIET=1; shift ;;
        --profile)
            shift
            PROFILE="${1:-}"
            [ -z "$PROFILE" ] && { echo "error: --profile requires a value" >&2; exit 1; }
            shift
            ;;
        *) shift ;;
    esac
done

case "$PROFILE" in
    chump|chump-proprietary|external-minimal) ;;
    *) echo "error: unknown profile '$PROFILE'; valid: chump, chump-proprietary, external-minimal" >&2; exit 1 ;;
esac

log() { [[ "$QUIET" == "0" ]] && echo "$@" || true; }

# RESILIENT-075: the symlink TARGET must be the MAIN worktree, never the current
# one. `git rev-parse --show-toplevel` returns whatever worktree we happen to run
# from — and this script installs hooks into EVERY worktree (the loop below),
# including the main repo's shared .git/hooks/. If we run it from a transient
# /tmp/chump-<gap> claim worktree, every worktree's hooks get symlinked into /tmp
# and SILENTLY break the instant that claim is reaped (git skips a dangling-symlink
# hook with no error — the whole gate layer vanishes fleet-wide). The main worktree
# is always the FIRST entry of `git worktree list --porcelain`, so we pin to it.
MAIN_WORKTREE="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
REPO_ROOT="${MAIN_WORKTREE:-$(git rev-parse --show-toplevel)}"
SRC_DIR="$REPO_ROOT/scripts/git-hooks"

# Defense in depth: never anchor the fleet's hooks under a temp dir. If the
# resolved main worktree is itself transient (shouldn't happen, but a bare-repo or
# misconfigured worktree could), refuse rather than install a self-destructing link.
case "$REPO_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*)
        echo "error (RESILIENT-075): resolved main worktree '$REPO_ROOT' is under a temp dir;" >&2
        echo "  refusing to anchor hooks there (they would break when the dir is reaped)." >&2
        echo "  Run install-hooks.sh from a stable checkout, or fix the main worktree path." >&2
        exit 1 ;;
esac

if [ ! -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR not found" >&2
    exit 1
fi

# Make every hook executable (forgetting chmod is the #1 install bug).
hook_count=0
for src in "$SRC_DIR"/*; do
    [ -f "$src" ] || continue
    chmod +x "$src"
    hook_count=$((hook_count + 1))
done

# Resolve hooks dir for each worktree from `git worktree list --porcelain`.
# Main worktree gets `.git/hooks/`; linked worktrees get
# `.git/worktrees/<name>/hooks/`. We use absolute paths in symlinks so the
# target resolves regardless of which dir the user is in when they commit.
worktree_count=0
while read -r line; do
    case "$line" in
        worktree\ *)
            wt_path="${line#worktree }"
            # Find its git dir.
            wt_gitdir=$(git -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null || true)
            if [ -z "$wt_gitdir" ]; then
                continue
            fi
            mkdir -p "$wt_gitdir/hooks"
            for src in "$SRC_DIR"/*; do
                [ -f "$src" ] || continue
                name=$(basename "$src")
                ln -sf "$src" "$wt_gitdir/hooks/$name"
            done
            # Write the profile so the hook knows which guards to activate.
            printf '%s\n' "$PROFILE" > "$wt_gitdir/chump-hook-profile"
            log "installed: $wt_gitdir/hooks/* -> $SRC_DIR/* (profile: $PROFILE)"
            worktree_count=$((worktree_count + 1))
            ;;
    esac
done < <(git worktree list --porcelain)

log ""
log "Installed $hook_count hook(s) into $worktree_count worktree(s)."
log "Re-run after every \`git worktree add\` to cover the new worktree."
log "Skip a hook for one commit: git commit --no-verify"

# INFRA-310: also install custom git merge drivers (state.sql regen, etc.)
# Drivers live in .git/config (not committed), so each fresh checkout / linked
# worktree needs the install. Cheap and idempotent.
if [ -x "$REPO_ROOT/scripts/setup/install-merge-drivers.sh" ]; then
    log ""
    log "Installing INFRA-310 merge drivers ..."
    bash "$REPO_ROOT/scripts/setup/install-merge-drivers.sh" 2>&1 | sed 's/^/  /'
fi

# INFRA-1136: install the gh wrapper into ~/.local/bin so interactive shells
# also go through the INFRA-1079/1103 throttle (without this, bare `gh` from
# Claude/operator sessions bypasses the throttle and burns the GraphQL bucket).
# Failure is non-fatal — the user's PATH may not include ~/.local/bin, in
# which case the installer logs a warning and exits 4. Hooks themselves
# already installed at this point; the gh wrapper is an extra layer.
if [ -x "$REPO_ROOT/scripts/setup/install-gh-shim.sh" ]; then
    log ""
    log "Installing INFRA-1136 gh wrapper ..."
    CHUMP_GH_INSTALL_QUIET=$QUIET bash "$REPO_ROOT/scripts/setup/install-gh-shim.sh" 2>&1 | sed 's/^/  /' || true
fi
