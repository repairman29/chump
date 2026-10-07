#!/usr/bin/env bash
# RESILIENT-1552 (child of RESILIENT-1548): summarize median pre-push hook
# duration and CI wall-clock from ambient.jsonl, split by PR class
# (docs-only / single-crate / full), so the parent's "CI wall-clock and
# push time dropped materially" claim can be read off a signal instead of
# asserted. Read-only; never gates anything.
#
# Usage: scripts/dev/ci-wall-clock-report.sh [--ambient PATH]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ambient) AMBIENT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$AMBIENT" ]]; then
    echo "no ambient log at $AMBIENT — nothing to report." >&2
    exit 0
fi

median() {
    # reads newline-separated numbers on stdin, prints the median
    sort -n | awk '{a[NR]=$1} END {
        if (NR==0) { print "n/a"; exit }
        if (NR % 2) { print a[(NR+1)/2] } else { print (a[NR/2]+a[NR/2+1])/2 }
    }'
}

echo "=== pre-push hook duration (seconds), median by PR class ==="
for class in docs-only single-crate full unknown; do
    n=$(grep -c "\"kind\":\"prepush_hook_duration\".*\"pr_class\":\"${class}\"" "$AMBIENT" 2>/dev/null || true)
    [[ -z "$n" || "$n" -eq 0 ]] && continue
    vals=$(grep "\"kind\":\"prepush_hook_duration\".*\"pr_class\":\"${class}\"" "$AMBIENT" \
        | grep -oE '"duration_s":[0-9]+' | cut -d: -f2)
    med=$(echo "$vals" | median)
    printf '  %-12s n=%-4s median=%ss\n' "$class" "$n" "$med"
done

echo
echo "=== CI wall-clock (seconds), median by PR class ==="
for class in docs-only scripts-only full; do
    n=$(grep -c "\"kind\":\"ci_wall_clock\".*\"pr_class\":\"${class}\"" "$AMBIENT" 2>/dev/null || true)
    [[ -z "$n" || "$n" -eq 0 ]] && continue
    vals=$(grep "\"kind\":\"ci_wall_clock\".*\"pr_class\":\"${class}\"" "$AMBIENT" \
        | grep -oE '"duration_s":[0-9]+' | cut -d: -f2)
    med=$(echo "$vals" | median)
    printf '  %-12s n=%-4s median=%ss\n' "$class" "$n" "$med"
done
