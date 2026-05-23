#!/usr/bin/env bash
# scripts/coord/pr-pulse.sh — INFRA-1897
#
# PR oversight one-shot. Queries open PRs (cache-first per INFRA-1081);
# computes queue-health counts + age percentiles; prints a 5-line operator-
# readable summary AND emits `kind=pr_oversight_snapshot` to ambient.jsonl
# with the full data as JSON payload.
#
# Use cases:
#   - Operator on-demand: `bash scripts/coord/pr-pulse.sh` for a quick read
#   - Cron / launchd every 5 min for trend telemetry
#   - Embedded in shell scripts via grep / jq (parses 5-line text easily)
#
# Bypass: CHUMP_PR_PULSE_NO_EMIT=1 prints without emitting (dry-run).

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"

# Get open PR list (cache-first via lib/github_cache.sh if available)
LIB="$REPO/scripts/coord/lib/github_cache.sh"
if [[ -f "$LIB" ]]; then
    # shellcheck source=/dev/null
    source "$LIB"
fi

# Fallback: direct gh query
prs_json="$(gh pr list --state open --limit 50 \
    --json number,mergeStateStatus,autoMergeRequest,createdAt 2>/dev/null || echo '[]')"

if [[ -z "$prs_json" || "$prs_json" == "[]" ]]; then
    echo "[pr-pulse] queue empty (no open PRs)"
    exit 0
fi

# Compute counts + age percentiles via python (more portable than shell math)
read -r total dirty blocked_armed blocked_failed age_p50 age_p99 <<<"$(
    printf '%s' "$prs_json" | python3 -c '
import json, sys, datetime
prs = json.load(sys.stdin)
now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
total = len(prs)
dirty = sum(1 for p in prs if p.get("mergeStateStatus") == "DIRTY")
blocked = [p for p in prs if p.get("mergeStateStatus") == "BLOCKED"]
blocked_armed = sum(1 for p in blocked if p.get("autoMergeRequest"))
blocked_failed = len(blocked) - blocked_armed
ages = []
for p in prs:
    c = p.get("createdAt","")
    if c:
        try:
            ct = datetime.datetime.strptime(c, "%Y-%m-%dT%H:%M:%SZ")
            ages.append((now - ct).total_seconds() / 60)
        except: pass
ages.sort()
def pct(p):
    if not ages: return 0
    i = int(len(ages) * p / 100)
    return int(ages[min(i, len(ages)-1)])
print(total, dirty, blocked_armed, blocked_failed, pct(50), pct(99))
'
)"

# Operator-readable summary (5 lines, grep/jq friendly)
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '[pr-pulse %s] open=%s dirty=%s\n' "$ts" "$total" "$dirty"
printf '[pr-pulse]   blocked+armed=%s (auto-merge cycling)\n' "$blocked_armed"
printf '[pr-pulse]   blocked-failed=%s (likely stuck, need diagnosis)\n' "$blocked_failed"
printf '[pr-pulse]   age_p50=%smin age_p99=%smin\n' "$age_p50" "$age_p99"
# Health verdict (one of: HEALTHY / SATURATED / WEDGED)
verdict="HEALTHY"
if (( dirty >= 5 || blocked_failed >= 5 )); then verdict="WEDGED"; fi
if (( total >= 12 && total > 0 && (dirty + blocked_failed) >= total/2 )); then verdict="SATURATED"; fi
printf '[pr-pulse]   verdict=%s\n' "$verdict"

# Emit ambient event (unless bypassed)
if [[ "${CHUMP_PR_PULSE_NO_EMIT:-0}" != "1" ]]; then
    EMIT="$REPO/scripts/dev/ambient-emit.sh"
    if [[ -x "$EMIT" ]]; then
        "$EMIT" pr_oversight_snapshot \
            "total=$total" "dirty=$dirty" \
            "blocked_armed=$blocked_armed" "blocked_failed=$blocked_failed" \
            "age_p50_min=$age_p50" "age_p99_min=$age_p99" \
            "verdict=$verdict" 2>/dev/null || true
    fi
fi

exit 0
