#!/usr/bin/env bash
# 30-recurring-gap-pattern-detector.sh — INFRA-249
#
# Nightly run of the recurring-gap-pattern detector. Surfaces meta-patterns
# the agent fleet has been filing without realising. ALERT lines emit to
# ambient.jsonl so the next agent's session-start tail picks them up.
#
# Conventions: see scripts/overnight/README.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/recurring-gap-pattern-detector.sh"

if [ ! -x "$DETECTOR" ]; then
    echo "[30-recurring-gap-pattern-detector] WARN: $DETECTOR missing or not executable; skipping"
    exit 0
fi

# Default settings: 7-day window, threshold of 3 keyword overlaps.
# Tighter than the on-demand defaults so nightly noise stays low; on-demand
# invocations from agents can use --threshold 2 for finer-grained scans.
exec "$DETECTOR" --days 7 --threshold 3
