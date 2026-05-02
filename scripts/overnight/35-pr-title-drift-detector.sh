#!/usr/bin/env bash
# 35-pr-title-drift-detector.sh — INFRA-104
#
# Nightly scan of recently-merged PRs for title-vs-implementation drift.
# Surfaces PRs whose title claims gap-ID work but the diff/body/files have
# no signature of that gap actually being addressed. Catches the "INFRA-XXX:
# rename file Y" titled PR whose actual diff edits an unrelated docs/Z.md.
#
# Conventions: see scripts/overnight/README.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/pr-title-drift-detector.sh"

if [ ! -x "$DETECTOR" ]; then
    echo "[35-pr-title-drift-detector] WARN: $DETECTOR missing or not executable; skipping"
    exit 0
fi

# Default: scan the last 25 merged PRs. Tight enough to keep noise low,
# wide enough that a 1-day-of-PRs window is fully covered.
exec "$DETECTOR" --recent 25 --quiet
