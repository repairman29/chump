#!/usr/bin/env bash
# scripts/setup/install-gh-shim.sh — INFRA-1136
#
# INFRA-1103 added throttle to scripts/coord/lib/gh-shim/gh, but the shim
# only activates when a script sources scripts/coord/lib/github.sh — which
# prepends the shim dir to PATH for that subshell. Interactive Claude /
# operator shells never source it, so `gh` resolves to the real binary
# directly and bypasses the throttle.
#
# This installer puts a wrapper at ~/.local/bin/gh (or $CHUMP_GH_SHIM_DIR)
# so every interactive shell whose PATH includes that dir hits the throttle
# automatically. The wrapper just execs the repo shim with the original
# argv — all throttle logic lives in the repo copy (single source of truth).
#
# Idempotent. Re-running detects an existing install with the same target
# and skips. CHUMP_GH_NO_SHIM=1 in env still bypasses (handled by the shim).
#
# Usage:
#   bash scripts/setup/install-gh-shim.sh             # install to ~/.local/bin
#   bash scripts/setup/install-gh-shim.sh --dir DIR   # install to a custom dir
#   bash scripts/setup/install-gh-shim.sh --uninstall # remove
#   CHUMP_GH_INSTALL_QUIET=1 bash …                   # suppress non-error output

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && cd .. && pwd -P)"
SHIM_SRC="$REPO_ROOT/scripts/coord/lib/gh-shim/gh"

INSTALL_DIR="${CHUMP_GH_SHIM_DIR:-$HOME/.local/bin}"
ACTION="install"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --uninstall) ACTION="uninstall"; shift ;;
        --help|-h)
            sed -n '2,21p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "[install-gh-shim] unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() { [ "${CHUMP_GH_INSTALL_QUIET:-0}" = "1" ] || echo "[install-gh-shim] $*"; }

if [ ! -x "$SHIM_SRC" ]; then
    echo "[install-gh-shim] shim source not executable at $SHIM_SRC" >&2
    exit 1
fi

TARGET="$INSTALL_DIR/gh"

if [ "$ACTION" = "uninstall" ]; then
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        # Only remove if it's our wrapper. Detect via marker line.
        if [ -f "$TARGET" ] && grep -q 'CHUMP_GH_WRAPPER_VERSION=' "$TARGET" 2>/dev/null; then
            rm -f "$TARGET"
            log "removed $TARGET"
        else
            log "$TARGET exists but is not a chump wrapper — leaving alone"
        fi
    fi
    exit 0
fi

# Avoid clobbering the real gh if someone installed gh into $INSTALL_DIR.
# Bail out unless the existing file is already our wrapper (idempotent re-run).
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    if [ -f "$TARGET" ] && grep -q 'CHUMP_GH_WRAPPER_VERSION=' "$TARGET" 2>/dev/null; then
        # Re-write to keep the embedded repo path current (handles repo moves).
        :
    else
        echo "[install-gh-shim] $TARGET exists and is NOT a chump wrapper." >&2
        echo "[install-gh-shim] Refusing to overwrite. Move/remove it manually if you want the shim installed here." >&2
        exit 3
    fi
fi

mkdir -p "$INSTALL_DIR"

# The wrapper hardcodes the repo path so it works regardless of whether the
# shim source is on the user's PATH. The shim itself resolves the real gh
# by walking PATH and skipping its own dir; since this wrapper lives at
# $INSTALL_DIR/gh (which IS on PATH), and the wrapper execs the shim from
# its real repo location, the shim's own SHIM_DIR is the repo path — so the
# PATH walk correctly skips the repo dir and finds /opt/homebrew/bin/gh.
cat > "$TARGET" <<EOF
#!/usr/bin/env bash
# Chump gh wrapper — INFRA-1136. Routes every gh invocation through the
# throttled shim at:
#   $SHIM_SRC
# Re-generate with: bash $REPO_ROOT/scripts/setup/install-gh-shim.sh
# Bypass for a single call: CHUMP_GH_NO_SHIM=1 gh …
CHUMP_GH_WRAPPER_VERSION=1
# Strip this wrapper's dir from PATH before exec'ing the shim. The shim
# resolves the real gh by walking PATH minus its own dir — without this
# strip, the shim would re-discover THIS wrapper and recurse.
__chump_gh_wrapper_dir="$INSTALL_DIR"
PATH="\$(printf '%s' "\$PATH" | tr ':' '\\n' | grep -vFx "\$__chump_gh_wrapper_dir" | tr '\\n' ':' | sed 's/:\$//')"
export PATH
exec "$SHIM_SRC" "\$@"
EOF
chmod +x "$TARGET"

log "installed: $TARGET -> $SHIM_SRC"

# Verify PATH ordering. The wrapper only matters if $INSTALL_DIR comes
# BEFORE the dir holding the real gh.
REAL_GH="$(PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vFx "$INSTALL_DIR" | tr '\n' ':' | sed 's/:$//')" command -v gh 2>/dev/null || true)"
if [ -n "$REAL_GH" ]; then
    log "real gh: $REAL_GH"
fi

PATH_CHECK="$(command -v gh 2>/dev/null || true)"
if [ "$PATH_CHECK" != "$TARGET" ]; then
    echo "[install-gh-shim] WARN: \`which gh\` returns '$PATH_CHECK', not '$TARGET'." >&2
    echo "[install-gh-shim]   Make sure $INSTALL_DIR is in PATH BEFORE the dir holding the real gh." >&2
    echo "[install-gh-shim]   Add to your shell rc (~/.bashrc, ~/.zshrc):" >&2
    echo "[install-gh-shim]     export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
    exit 4
fi

log "verified: \`which gh\` -> $TARGET"
log "done. Every interactive gh call now goes through the throttle."
exit 0
