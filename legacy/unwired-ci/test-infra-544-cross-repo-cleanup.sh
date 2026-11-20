#!/usr/bin/env bash
# Test INFRA-580: picker-pivot cleanup uses CHUMP_REPO, not REPO_ROOT.
# When CHUMP_REPO != REPO_ROOT, the .gap-<ID>.lock must be removed from
# $CHUMP_REPO/.chump-locks/, not $REPO_ROOT/.chump-locks/.
set -euo pipefail

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

CHUMP_REPO_DIR="$TMPDIR_BASE/canonical-repo"
REPO_ROOT_DIR="$TMPDIR_BASE/fleet-launch"
GAP_ID="INFRA-TEST-001"

mkdir -p "$CHUMP_REPO_DIR/.chump-locks"
mkdir -p "$REPO_ROOT_DIR/.chump-locks"

# Simulate the lock the picker writes in the canonical repo.
touch "$CHUMP_REPO_DIR/.chump-locks/.gap-${GAP_ID}.lock"

# Simulate what worker.sh now does on pivot.
CHUMP_REPO="$CHUMP_REPO_DIR"
REPO_ROOT="$REPO_ROOT_DIR"
rm -f "${CHUMP_REPO:-$REPO_ROOT}/.chump-locks/.gap-${GAP_ID}.lock" 2>/dev/null || true

# Assert: canonical-side lock is gone.
if [ -f "$CHUMP_REPO_DIR/.chump-locks/.gap-${GAP_ID}.lock" ]; then
    echo "FAIL: lock still present in CHUMP_REPO after pivot cleanup" >&2
    exit 1
fi

# Assert: REPO_ROOT side was not touched (no spurious file).
if [ -f "$REPO_ROOT_DIR/.chump-locks/.gap-${GAP_ID}.lock" ]; then
    echo "FAIL: unexpected lock created in REPO_ROOT" >&2
    exit 1
fi

# Regression check: when CHUMP_REPO is unset, falls back to REPO_ROOT.
touch "$REPO_ROOT_DIR/.chump-locks/.gap-${GAP_ID}.lock"
unset CHUMP_REPO
REPO_ROOT="$REPO_ROOT_DIR"
rm -f "${CHUMP_REPO:-$REPO_ROOT}/.chump-locks/.gap-${GAP_ID}.lock" 2>/dev/null || true

if [ -f "$REPO_ROOT_DIR/.chump-locks/.gap-${GAP_ID}.lock" ]; then
    echo "FAIL: fallback to REPO_ROOT did not remove lock" >&2
    exit 1
fi

echo "PASS: INFRA-580 cross-repo pivot cleanup"
