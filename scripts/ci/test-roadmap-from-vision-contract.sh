#!/usr/bin/env bash
# INFRA-2267 Phase 1 — smoke test for RoadmapFromVisionContract
#
# Runs the Rust unit tests that cover:
#   - type compiles + serde roundtrip
#   - Validate rejects each violation (empty groups, missing AC, bad depends_on,
#     confidence out of range, empty title)
#   - prompt() includes all 6 interpolation points
#   - ModelTier is Opus
#
# Target: <30s warm, <60s cold (no network; cargo incremental compile only).
# Exit 0 on all green, non-zero on any failure.
#
# Usage: bash scripts/ci/test-roadmap-from-vision-contract.sh [--verbose]

set -euo pipefail

VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CARGO="${CARGO:-cargo}"
PATH="$HOME/.cargo/bin:$PATH"

log() { echo "[test-roadmap-from-vision-contract] $*"; }

log "Running RoadmapFromVisionContract unit tests (chump-handoff crate)..."

CARGO_ARGS=(
    test
    -p chump-handoff
    --lib                        # only lib tests; no integration tests (Phase 2)
    -- "tests_roadmap_from_vision"  # module filter
    --test-threads=4
)

if [[ "$VERBOSE" -eq 1 ]]; then
    CARGO_ARGS+=(--nocapture)
fi

start_s=$(date +%s)

if [[ "$VERBOSE" -eq 1 ]]; then
    "$CARGO" "${CARGO_ARGS[@]}"
else
    "$CARGO" "${CARGO_ARGS[@]}" 2>&1
fi

end_s=$(date +%s)
elapsed=$(( end_s - start_s ))

log "All tests passed in ${elapsed}s."

if [[ "$elapsed" -gt 30 ]]; then
    log "WARN: test suite took ${elapsed}s (target <30s warm). Consider --release or incremental cache."
fi

exit 0
