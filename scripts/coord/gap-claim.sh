#!/usr/bin/env bash
# gap-claim.sh — INFRA-1025: thin wrapper. Real logic lives in `chump claim`.
#
# Previously: 585-line shell script that created worktrees, wrote lease JSON,
# and wrote state.db. As of INFRA-1025, all of that is atomic Rust in
# src/atomic_claim.rs (run via `chump claim`).
#
# This wrapper preserves backward compatibility for any caller that invokes
# gap-claim.sh directly. Args pass through unchanged:
#   gap-claim.sh <GAP-ID> [--paths CSV] [--speculative] [--resume]
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: gap-claim.sh <GAP-ID> [--paths CSV] [--resume]" >&2
    exit 1
fi

# Resolve chump binary: prefer release build, fall back to debug build, then PATH.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -n "$REPO_ROOT" && -x "$REPO_ROOT/target/release/chump" ]]; then
    CHUMP="$REPO_ROOT/target/release/chump"
elif [[ -n "$REPO_ROOT" && -x "$REPO_ROOT/target/debug/chump" ]]; then
    CHUMP="$REPO_ROOT/target/debug/chump"
else
    CHUMP="$(command -v chump 2>/dev/null)" || {
        echo "[gap-claim] ERROR: chump binary not found on PATH and neither target/release/chump nor target/debug/chump exists." >&2
        echo "[gap-claim] Build it with: cargo build --release" >&2
        exit 1
    }
fi

exec "$CHUMP" claim "$@"
