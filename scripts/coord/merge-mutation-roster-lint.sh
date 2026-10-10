#!/usr/bin/env bash
# scripts/coord/merge-mutation-roster-lint.sh — RESILIENT-1563
#
# Roster-lint: FAILS if more than one merge-mutation organ is `enabled` in
# organ-manifest.txt. This is the count-axis complement to RESILIENT-1559
# (the override-to-/bin/true axis, "can an organ be silenced") — this lint
# answers "how many merge-mutation organs are counted as live right now",
# independent of the shared merge-pipeline-driver.lock (scripts/coord/lib/
# merge-pipeline-lock.sh) that prevents them from racing EACH OTHER at
# runtime if more than one ever does end up enabled.
#
# The four named merge-mutation organs (per the gap spec):
#   serializer            chump-merge-serializer.timer     (merge-serializer.sh)
#   armed-rebaser          chump-armed-rebaser.timer         (armed-pr-rebaser.sh)
#   keep-mergeable          chump-keep-mergeable-organ.timer  (keep-mergeable-organ.sh)
#   shepherd-with-merge     chump-pr-shepherd.timer           (pr-shepherd-daemon.sh's
#                                                              INFRA-2346 tier-A
#                                                              admin-merge path)
#
# A unit counts as "enabled" if organ-manifest.txt has an `enabled` line for
# it (not `disabled`/commented/paging_off). `paging_off` and absent/commented
# lines do not count — those are RESILIENT-1559's silencing mechanism, already
# proven effective; this lint only counts the ones left live.
#
# Usage:
#   scripts/coord/merge-mutation-roster-lint.sh [--manifest PATH]
#
# Exit codes:
#   0   exactly one (or zero) merge-mutation organ enabled
#   1   more than one merge-mutation organ enabled — DOUBLE-DRIVER
#   2   manifest file not found / unreadable

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${1:-}"
if [[ "${1:-}" == "--manifest" ]]; then
    MANIFEST="${2:-}"
fi
MANIFEST="${MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"

if [[ ! -f "$MANIFEST" ]]; then
    echo "[merge-mutation-roster-lint] FAIL: manifest not found: $MANIFEST" >&2
    exit 2
fi

# organ-name:unit-name pairs. Declared as a flat array (name, unit, name, unit, ...)
# for bash-3.x compatibility (no associative arrays).
ROSTER=(
    "serializer"            "chump-merge-serializer.timer"
    "armed-rebaser"         "chump-armed-rebaser.timer"
    "keep-mergeable"        "chump-keep-mergeable-organ.timer"
    "shepherd-with-merge"   "chump-pr-shepherd.timer"
)

enabled_organs=()
idx=0
while [[ $idx -lt ${#ROSTER[@]} ]]; do
    name="${ROSTER[$idx]}"
    unit="${ROSTER[$((idx + 1))]}"
    idx=$((idx + 2))
    # Must match a line that STARTS with "enabled" + whitespace + this exact
    # unit token (word-boundary via trailing space/EOL) — so e.g.
    # chump-pr-shepherd.timer doesn't false-match chump-pr-shepherd-x.timer,
    # and a `disabled`/commented/paging_off line never counts.
    if grep -qE "^enabled[[:space:]]+${unit//./\\.}([[:space:]]|\$)" "$MANIFEST"; then
        enabled_organs+=("$name ($unit)")
    fi
done

count="${#enabled_organs[@]}"

if [[ "$count" -gt 1 ]]; then
    echo "[merge-mutation-roster-lint] FAIL: ${count} merge-mutation organs enabled simultaneously (expected at most 1):" >&2
    for o in "${enabled_organs[@]}"; do
        echo "  - $o" >&2
    done
    echo "[merge-mutation-roster-lint] Exactly one organ must drive force-push/update-branch/pr-merge mutations (RESILIENT-1563)." >&2
    echo "[merge-mutation-roster-lint] Disable all but one via organ-manifest.txt (see RESILIENT-1559 for the paging_off/disable mechanism)." >&2
    exit 1
fi

if [[ "$count" -eq 1 ]]; then
    echo "[merge-mutation-roster-lint] PASS: exactly one merge-mutation organ enabled — ${enabled_organs[0]}"
else
    echo "[merge-mutation-roster-lint] PASS: zero merge-mutation organs enabled"
fi
exit 0
