#!/usr/bin/env bash
# ensure-cargo-on-path.sh — shared CI test helper, INFRA-1600 follow-up.
#
# Ensure `cargo` and `rustc` are on PATH for the current shell. On
# self-hosted macOS runners the actions-runner launchd service's
# inherited PATH does NOT include $HOME/.cargo/bin where rustup installs
# the toolchain. Cargo-using CI scripts get "cargo: command not found"
# (exit 127) when this isn't sourced.
#
# Usage in a CI test script that calls `cargo` directly or transitively:
#   source "$(dirname "$0")/lib/ensure-cargo-on-path.sh"
#
# Idempotent: re-sourcing in the same shell is a no-op.
#
# Honors any pre-existing cargo on PATH first — operators can override
# by exporting PATH themselves.

if command -v cargo >/dev/null 2>&1; then
    return 0 2>/dev/null || true
fi

# rustup-style install: source ~/.cargo/env if it exists (sets PATH).
if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
fi

# Fallback: explicit PATH augmentation if .cargo/env didn't exist.
if ! command -v cargo >/dev/null 2>&1; then
    if [[ -x "$HOME/.cargo/bin/cargo" ]]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
fi

# Also ensure homebrew tools are reachable (timeout, jq) — surfaced in the
# 2026-05-16 ACP cascade fix.
for brewbin in /opt/homebrew/bin /usr/local/bin; do
    if [[ -d "$brewbin" ]] && [[ ":$PATH:" != *":$brewbin:"* ]]; then
        export PATH="$brewbin:$PATH"
    fi
done

# Final check + diagnostic on failure.
if ! command -v cargo >/dev/null 2>&1; then
    echo "[ensure-cargo-on-path] FATAL: cargo not found after sourcing" >&2
    echo "  Tried \$HOME/.cargo/env, \$HOME/.cargo/bin/cargo" >&2
    echo "  Current PATH: $PATH" >&2
    exit 127
fi
