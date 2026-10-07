#!/usr/bin/env bash
# merge-mutation-roster-lint.sh — RESILIENT-1563.
#
# Count-axis complement to RESILIENT-1559 (which closed the OVERRIDE axis: an
# organ disarmed via a /bin/true symlink can't silently re-arm). This closes
# the COUNT axis: a node must never have more than ONE of the four
# merge-mutation organs enabled at once, regardless of each organ's own
# disarm state. Two live drivers racing the same PR's force-push/
# update-branch/pr-merge path is the exact class that stalled ships to zero
# once already (RESILIENT-1054: armed-rebaser vs merge-serializer).
#
# The four named merge-mutation organs:
#   shepherd-with-merge   chump-pr-shepherd.timer        scripts/coord/pr-shepherd-daemon.sh
#   serializer            chump-merge-serializer.timer   scripts/coord/merge-serializer.sh
#   armed-rebaser         chump-armed-rebaser.timer      scripts/coord/armed-pr-rebaser.sh
#   keep-mergeable        com.chump.keep-mergeable-organ scripts/coord/keep-mergeable-organ.sh
#
# Usage:
#   bash scripts/coord/merge-mutation-roster-lint.sh [--manifest PATH] [--json]
#
# Exit codes:
#   0  — 0 or 1 merge-mutation organ enabled (healthy)
#   1  — 2+ merge-mutation organs enabled (the double-driver hazard)
#
# Env overrides (test fixtures):
#   CHUMP_ROSTER_LINT_MANIFEST            — override organ-manifest.txt path
#   CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE — force keep-mergeable's state to
#                                            "enabled" or "disabled" (keep-mergeable
#                                            has no organ-manifest.txt row — it is
#                                            installed standalone via
#                                            install-keep-mergeable-organ-launchd.sh
#                                            — so its liveness signal is the
#                                            launchd plist file, not a manifest line)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MANIFEST="${CHUMP_ROSTER_LINT_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"
JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# manifest_state <timer-name> — echoes enabled|disabled|paging_off|absent
manifest_state() {
    local timer="$1" line
    [[ -f "$MANIFEST" ]] || { echo "absent"; return; }
    line="$(grep -E "^(enabled|disabled|paging_off) +${timer//./\\.}( |\$)" "$MANIFEST" | head -1)"
    if [[ -z "$line" ]]; then
        echo "absent"
    else
        awk '{print $1}' <<<"$line"
    fi
}

# keep_mergeable_state — keep-mergeable-organ has no organ-manifest.txt row
# (RESILIENT-342 installed it standalone via a dedicated launchd installer),
# so its liveness signal is the installed plist, not a manifest line.
keep_mergeable_state() {
    if [[ -n "${CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE:-}" ]]; then
        echo "$CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE"
        return
    fi
    local plist="$HOME/Library/LaunchAgents/com.chump.keep-mergeable-organ.plist"
    if [[ -f "$plist" ]] && command -v launchctl >/dev/null 2>&1 \
        && launchctl list 2>/dev/null | grep -q 'com\.chump\.keep-mergeable-organ'; then
        echo "enabled"
    elif [[ -f "$plist" ]]; then
        echo "disabled"
    else
        echo "absent"
    fi
}

declare -a LABELS=(shepherd-with-merge serializer armed-rebaser keep-mergeable)
declare -a STATES

STATES[0]="$(manifest_state "chump-pr-shepherd.timer")"
STATES[1]="$(manifest_state "chump-merge-serializer.timer")"
STATES[2]="$(manifest_state "chump-armed-rebaser.timer")"
STATES[3]="$(keep_mergeable_state)"

enabled_count=0
enabled_labels=()
for i in "${!LABELS[@]}"; do
    if [[ "${STATES[$i]}" == "enabled" ]]; then
        enabled_count=$((enabled_count + 1))
        enabled_labels+=("${LABELS[$i]}")
    fi
done

if [[ "$JSON" -eq 1 ]]; then
    printf '{"enabled_count":%d,"organs":[' "$enabled_count"
    for i in "${!LABELS[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        printf '{"label":"%s","state":"%s"}' "${LABELS[$i]}" "${STATES[$i]}"
    done
    printf ']}\n'
else
    echo "=== merge-mutation roster lint (RESILIENT-1563) ==="
    for i in "${!LABELS[@]}"; do
        printf '  %-20s %s\n' "${LABELS[$i]}" "${STATES[$i]}"
    done
    echo
fi

if [[ "$enabled_count" -gt 1 ]]; then
    [[ "$JSON" -eq 1 ]] || echo "FAIL: ${enabled_count} merge-mutation organs enabled (${enabled_labels[*]}) — exactly-one-driver invariant violated"
    exit 1
fi

[[ "$JSON" -eq 1 ]] || echo "PASS: ${enabled_count} merge-mutation organ(s) enabled"
exit 0
