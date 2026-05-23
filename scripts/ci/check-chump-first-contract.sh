#!/usr/bin/env bash
# check-chump-first-contract.sh — INFRA-1858 local mirror of CREDIBLE-046 no-anthropic-smoke
#
# Wraps scripts/ci/test-no-anthropic-smoke.sh with the same Anthropic-credential
# scrub that .github/workflows/no-anthropic-smoke.yml applies. Used by
# src/preflight.rs as the chump-first-contract local gate (CREDIBLE-046).
#
# Today's (2026-05-23) CREDIBLE-046 regression cost ~3h of throughput before
# #2404 fixed it; this gate catches that class of failure locally so the next
# regression of the chump-first contract surfaces in <30s instead of via CI.
#
# Bypass: CHUMP_PREFLIGHT_SKIP_CHUMPFIRST=1 (handled by preflight.rs caller)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Resolve the chump binary the CI workflow would use ─────────────────────
# Priority matches preflight gates above: CHUMP_BIN env > release > debug > PATH
CHUMP_BIN="${CHUMP_BIN:-}"
if [ -z "$CHUMP_BIN" ]; then
    for candidate in \
        "$REPO_ROOT/target/release/chump" \
        "$REPO_ROOT/target/debug/chump"; do
        if [ -x "$candidate" ]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$CHUMP_BIN" ]; then
    if command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "[chump-first-contract] ERROR: chump binary not found. Build with: cargo build --bin chump" >&2
        exit 2
    fi
fi

if [ ! -x "scripts/ci/test-no-anthropic-smoke.sh" ]; then
    echo "[chump-first-contract] ERROR: scripts/ci/test-no-anthropic-smoke.sh missing" >&2
    exit 2
fi

# ── Run the smoke under the same env-scrub the CI workflow applies ─────────
# Hard-unset Anthropic creds for the child process (don't affect parent shell)
CHUMP_BIN="$CHUMP_BIN" \
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
CHUMP_SHIP_NO_AUTOSTAGE=1 \
ANTHROPIC_API_KEY="" \
CLAUDE_CODE_OAUTH_TOKEN="" \
    bash scripts/ci/test-no-anthropic-smoke.sh
