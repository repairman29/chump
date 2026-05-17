#!/usr/bin/env bash
# discover-chump-bin.sh — shared CI test helper, INFRA-1437 follow-up.
#
# Set $CHUMP_BIN to the path of a built chump binary, checking the
# CARGO_TARGET_DIR shared-cache path first (INFRA-1540 self-hosted runners
# redirect cargo output there), then the legacy repo-local target/ dirs.
#
# Usage in a CI test script:
#   source "$(dirname "$0")/lib/discover-chump-bin.sh"
#
# Caller must have $REPO_ROOT defined. After sourcing, $CHUMP_BIN is set
# OR the script exits with a clear diagnostic + actionable build hint.
#
# Honors an existing $CHUMP_BIN env var if it points at an executable file —
# allows operators to override via `CHUMP_BIN=/path/to/chump bash test-foo.sh`.

# If caller set CHUMP_BIN and it's executable, use it as-is.
if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "$CHUMP_BIN" ]]; then
    :  # keep as-is
elif [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "${REPO_ROOT:-}/$CHUMP_BIN" ]]; then
    CHUMP_BIN="$REPO_ROOT/$CHUMP_BIN"
elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/release/chump" ]]; then
    # Self-hosted runner with shared cache (INFRA-1540).
    CHUMP_BIN="$CARGO_TARGET_DIR/release/chump"
elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
elif [[ -x "${REPO_ROOT:-}/target/release/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/release/chump"
elif [[ -x "${REPO_ROOT:-}/target/debug/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
else
    echo "[discover-chump-bin] ERROR: no chump binary found." >&2
    echo "  Tried CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-<unset>}/{release,debug}/chump" >&2
    echo "  Tried $REPO_ROOT/target/{release,debug}/chump" >&2
    echo "  Build with: cargo build --release   (or cargo build for debug)" >&2
    exit 1
fi

export CHUMP_BIN
