#!/usr/bin/env bash
# Nightly run of the stalled-P0 detector (RESILIENT-1582).
# Surfaces P0 gaps that have been open unclaimed for > 24 hours.
#
# Conventions: see scripts/overnight/README.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/stalled-p0-detector.sh"

if [ ! -x "$DETECTOR" ]; then
    echo "[25-stalled-p0-detector] WARN: $DETECTOR missing or not executable; skipping"
    exit 0
fi

# Run with default thresholds (24 hours for stalled P0 alarm)
exec "$DETECTOR"
