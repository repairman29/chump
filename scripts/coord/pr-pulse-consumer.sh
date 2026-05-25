#!/usr/bin/env bash
# scripts/coord/pr-pulse-consumer.sh — INFRA-1898
#
# Consumer daemon for pr-pulse (INFRA-1897) oversight emits. Watches
# .chump-locks/ambient.jsonl for kind=pr_oversight_snapshot and acts on
# the verdict:
#
#   verdict=WEDGED     → DM each lane curator with their worst PR + rebase hint
#   verdict=SATURATED  → page operator via operator-recall.sh (INFRA-626)
#   verdict=HEALTHY    → no-op
#
# Throttle: same verdict won't re-fire within CHUMP_PULSE_CONSUMER_THROTTLE_MIN
# (default 30) minutes — debounce in .chump-locks/pr-pulse-consumer-state.jsonl.
#
# Bypass: CHUMP_PULSE_CONSUMER_DISABLED=1.
#
# Run mode: one-shot (called by cron / launchd every N min) — NOT a tail-follow
# daemon. Tail-following ambient.jsonl is fragile across rotations. Poll-based
# is simpler and matches the upstream pr-pulse 5-min cron cadence.

set -uo pipefail

# Quick bypass
[[ "${CHUMP_PULSE_CONSUMER_DISABLED:-0}" == "1" ]] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE="$REPO_ROOT/.chump-locks/pr-pulse-consumer-state.jsonl"
THROTTLE_MIN="${CHUMP_PULSE_CONSUMER_THROTTLE_MIN:-30}"
DATE="${CHUMP_CONSUMER_DATE_OVERRIDE:-$(date -u +%Y-%m-%d)}"
WIZARD="${CHUMP_WIZARD_SESSION:-orchestrator-opus-${DATE}}"

mkdir -p "$(dirname "$STATE")"
touch "$STATE"

if [[ ! -f "$AMBIENT" ]]; then
    echo "[pr-pulse-consumer] ambient log missing: $AMBIENT"
    exit 0
fi

# Compute cutoff: now - THROTTLE_MIN minutes (ISO-8601 UTC)
cutoff="$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - '"$THROTTLE_MIN"' * 60))' 2>/dev/null)"

# Last action timestamp for this verdict (within throttle window).
recent_action() {
    local verdict="$1"
    awk -v verdict="$verdict" -v cutoff="$cutoff" -F'"' '
        $0 ~ ("\"verdict\":\"" verdict "\"") {
            # Extract ts (the second quoted string in the JSON line)
            if ($4 >= cutoff) { print $4; exit }
        }
    ' "$STATE"
}

record() {
    local verdict="$1"
    local action="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","verdict":"%s","action":"%s"}\n' "$ts" "$verdict" "$action" >> "$STATE"
}

# Get the most recent pr_oversight_snapshot from ambient (last 200 lines for scan window)
LATEST=$(tail -200 "$AMBIENT" 2>/dev/null \
    | grep '"kind":"pr_oversight_snapshot"' \
    | tail -1)

if [[ -z "$LATEST" ]]; then
    echo "[pr-pulse-consumer] no pr_oversight_snapshot in recent ambient (skipping)"
    exit 0
fi

# Extract verdict using grep-substring (avoid jq dependency in the daemon path)
VERDICT=$(echo "$LATEST" | grep -oE '"verdict":"[A-Z_]+"' | head -1 | cut -d'"' -f4)

if [[ -z "$VERDICT" ]]; then
    echo "[pr-pulse-consumer] could not parse verdict from: $LATEST"
    exit 0
fi

# HEALTHY: no-op
if [[ "$VERDICT" == "HEALTHY" ]]; then
    echo "[pr-pulse-consumer] verdict=HEALTHY — no action needed"
    exit 0
fi

# Throttle check
last="$(recent_action "$VERDICT")"
if [[ -n "$last" ]]; then
    echo "[pr-pulse-consumer] SKIP verdict=$VERDICT — last action at $last (within ${THROTTLE_MIN}min throttle)"
    exit 0
fi

# WEDGED: DM each lane curator with rebase hint
if [[ "$VERDICT" == "WEDGED" ]]; then
    echo "[pr-pulse-consumer] verdict=WEDGED — paging lane curators"
    ROLES=(target handoff ci-audit shepherd decompose md-links)
    msg_count=0
    for role in "${ROLES[@]}"; do
        curator="curator-opus-${role}-${DATE}"
        msg="PULSE-CONSUMER ALERT verdict=WEDGED — queue has DIRTY or BLOCKED-failed PRs in your lane. Pulse: bash scripts/coord/pr-pulse.sh. Rescue tools: /tmp/take-both-resolve.py + git rebase + force-push + gh pr merge --auto --squash. Reply DONE/STUCK to ${WIZARD}."
        if bash "$REPO_ROOT/scripts/coord/broadcast.sh" --to "$curator" WARN "$msg" >/dev/null 2>&1; then
            msg_count=$((msg_count + 1))
            echo "[pr-pulse-consumer] paged $curator"
        fi
    done
    record "$VERDICT" "paged_${msg_count}_curators"
    exit 0
fi

# SATURATED: page operator via operator-recall.sh
if [[ "$VERDICT" == "SATURATED" ]]; then
    echo "[pr-pulse-consumer] verdict=SATURATED — paging operator via operator-recall"
    reason="pr-pulse consumer detected SATURATED queue (12+ open / 5+ DIRTY) — wizard cycle alone insufficient; human attention needed"
    if [[ -x "$REPO_ROOT/scripts/dispatch/operator-recall.sh" ]]; then
        bash "$REPO_ROOT/scripts/dispatch/operator-recall.sh" --condition QUEUE_SATURATED --reason "$reason" 2>&1 | tail -2
        record "$VERDICT" "operator_recall_paged"
    else
        echo "[pr-pulse-consumer] WARN — operator-recall.sh missing; cannot escalate"
        record "$VERDICT" "operator_recall_unavailable"
    fi
    exit 0
fi

echo "[pr-pulse-consumer] unknown verdict: $VERDICT (no action)"
exit 0
