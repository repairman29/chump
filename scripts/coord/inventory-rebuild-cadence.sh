#!/usr/bin/env bash
# inventory-rebuild-cadence.sh — RESILIENT-220
#
# Runs `chump inventory` (META-271's tech-debt/dead-code detection system)
# on a schedule and emits a summary to ambient.jsonl. Without this, the
# detectors sit fully built and go silently unused indefinitely -- exactly
# what was found while diagnosing RESILIENT-220: 9 detector classes, all at
# zero findings, un-run for ~2 months since they shipped.
#
# Install: bash scripts/setup/install-inventory-rebuild-cadence.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 1
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

echo "[inventory-rebuild-cadence] $(date -u +%Y-%m-%dT%H:%M:%SZ) starting"

chump inventory rebuild
rebuild_rc=$?

stats_json="$(chump inventory class-stats --json 2>/dev/null)"
total_findings=0
unreviewed=0
if [[ -n "$stats_json" ]]; then
    total_findings="$(printf '%s' "$stats_json" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    print(sum(c.get('total_findings', 0) for c in d.get('classes', [])))
except Exception:
    print(0)
" 2>/dev/null)"
    unreviewed="$(printf '%s' "$stats_json" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    print(sum(c.get('total_findings', 0) - c.get('reviewed_count', 0) for c in d.get('classes', [])))
except Exception:
    print(0)
" 2>/dev/null)"
fi

if [[ -n "$AMBIENT" ]]; then
    mkdir -p "$(dirname "$AMBIENT")"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"inventory_rebuild_tick","total_findings":%s,"unreviewed_count":%s,"rebuild_rc":%s}\n' \
        "$ts" "${total_findings:-0}" "${unreviewed:-0}" "$rebuild_rc" >> "$AMBIENT"
fi

echo "[inventory-rebuild-cadence] done: total_findings=${total_findings:-0} unreviewed=${unreviewed:-0} rc=$rebuild_rc"
echo "[inventory-rebuild-cadence] review with: chump inventory review-queue"
exit 0
