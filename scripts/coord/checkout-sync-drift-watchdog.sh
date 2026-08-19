#!/usr/bin/env bash
# checkout-sync-drift-watchdog.sh (RESILIENT-149) — the alarm for the
# checkout-sync daemon itself.
#
# scripts/ops/checkout-sync.sh (MISSION-027) keeps the running checkout
# fast-forwarded to origin/main on a 5-min cadence — but like auto-deploy
# before it (INFRA-3454 / merge-deploy-lag-watchdog.sh), it has NO alarm if
# the daemon stalls or the plist unloads: the checkout can then drift
# silently, and fleet daemons (ci-health-gate, farmer, auth-status, ...)
# keep executing stale scripts with no signal anyone would notice until a
# manual "git show origin/main:script > file" surgical deploy is needed
# (precedent: the 2026-06-15..20 outage). This watchdog measures the
# checkout's drift behind origin/main in BOTH commit count and merge age,
# and ALERTS + SELF-HEALS past either threshold.
#
# Logic:
#   drift == 0 commits                         -> current, emit
#                                                  checkout_sync_drift_ok, exit 0
#   drift > 0, commits <= K and age <= SLO      -> within tolerance, exit 0 (quiet)
#   drift > K commits OR oldest unsynced commit
#     older than SLO                            -> emit
#                                                  checkout_sync_drift_exceeded +
#                                                  self-heal (run checkout-sync.sh
#                                                  directly, then kickstart the
#                                                  launchd job as a belt-and-braces
#                                                  measure in case the daemon itself
#                                                  is wedged)
#
# Env:
#   CHUMP_CHECKOUT_DRIFT_MAX_COMMITS   default 10
#   CHUMP_CHECKOUT_DRIFT_SLO_SECS      default 1800 (30 min)
#   CHUMP_SYNC_TARGET_DIR              default: this script's repo root
#   CHUMP_CHECKOUT_DRIFT_NO_HEAL=1     alert only, don't self-heal
#
# Meant to run on a short launchd timer (e.g. every 10 min) — tighter than
# checkout-sync's own 5-min cadence, so a stalled sync surfaces fast.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_SYNC_TARGET_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
[[ -d "$REPO_ROOT/.git" || -f "$REPO_ROOT/.git" ]] || REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$STATE_DIR/ambient.jsonl}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MAX_COMMITS="${CHUMP_CHECKOUT_DRIFT_MAX_COMMITS:-10}"
SLO="${CHUMP_CHECKOUT_DRIFT_SLO_SECS:-1800}"

# scanner-anchor: "kind":"checkout_sync_drift_ok"
# scanner-anchor: "kind":"checkout_sync_drift_exceeded"
emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "${extra:+,$extra}" >> "$AMBIENT" 2>/dev/null || true
}

cd "$REPO_ROOT" || { echo "[drift-watchdog] FATAL: cannot cd to $REPO_ROOT"; exit 1; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "[drift-watchdog] FATAL: $REPO_ROOT is not a git checkout"
    exit 1
fi

CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [[ "$CUR_BRANCH" != "main" ]]; then
    echo "[drift-watchdog] SKIP: current branch is '$CUR_BRANCH', not main"
    exit 0
fi

if ! git fetch origin main --quiet 2>/dev/null; then
    echo "[drift-watchdog] WARN: fetch failed (offline?) — no-op this cycle"
    exit 0
fi

HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"
MAIN_SHA="$(git rev-parse origin/main 2>/dev/null)"
if [[ -z "$HEAD_SHA" || -z "$MAIN_SHA" ]]; then
    echo "[drift-watchdog] WARN: cannot resolve HEAD or origin/main — no-op"
    exit 0
fi

HEAD_SHORT="${HEAD_SHA:0:12}"
MAIN_SHORT="${MAIN_SHA:0:12}"

if [[ "$HEAD_SHA" == "$MAIN_SHA" ]]; then
    echo "[drift-watchdog] current: checkout=$HEAD_SHORT == main=$MAIN_SHORT"
    emit "checkout_sync_drift_ok" "\"sha\":\"$MAIN_SHORT\""
    exit 0
fi

DRIFT_COMMITS="$(git rev-list --count "HEAD..origin/main" 2>/dev/null || echo 0)"
# Age of the OLDEST commit the checkout hasn't seen yet — i.e. how long the
# checkout has been behind, not how old origin/main's tip is.
OLDEST_UNSYNCED_TIME="$(git log --reverse --format=%ct "HEAD..origin/main" 2>/dev/null | head -1)"
NOW="$(date +%s)"
DRIFT_AGE=$(( NOW - ${OLDEST_UNSYNCED_TIME:-$NOW} ))
[[ "$DRIFT_AGE" -lt 0 ]] && DRIFT_AGE=0
DRIFT_AGE_MIN=$(( DRIFT_AGE / 60 ))

if [[ "$DRIFT_COMMITS" -le "$MAX_COMMITS" && "$DRIFT_AGE" -le "$SLO" ]]; then
    echo "[drift-watchdog] behind but within tolerance: checkout=$HEAD_SHORT main=$MAIN_SHORT drift=${DRIFT_COMMITS}c/${DRIFT_AGE_MIN}m (max=${MAX_COMMITS}c/$(( SLO / 60 ))m) — sync pending"
    exit 0
fi

echo "[drift-watchdog] DRIFT EXCEEDED: checkout=$HEAD_SHORT main=$MAIN_SHORT drift=${DRIFT_COMMITS}c/${DRIFT_AGE_MIN}m > max=${MAX_COMMITS}c/$(( SLO / 60 ))m"
emit "checkout_sync_drift_exceeded" \
    "\"checkout_sha\":\"$HEAD_SHORT\",\"main_sha\":\"$MAIN_SHORT\",\"drift_commits\":$DRIFT_COMMITS,\"drift_age_secs\":$DRIFT_AGE,\"max_commits\":$MAX_COMMITS,\"slo_secs\":$SLO"

if [[ "${CHUMP_CHECKOUT_DRIFT_NO_HEAL:-0}" != "1" ]]; then
    echo "[drift-watchdog] self-heal: running checkout-sync.sh directly"
    CHUMP_SYNC_TARGET_DIR="$REPO_ROOT" bash "$SCRIPT_DIR/../ops/checkout-sync.sh" || true
    echo "[drift-watchdog] self-heal: kickstarting com.chump.checkout-sync (in case the daemon itself is wedged)"
    launchctl kickstart -k "gui/$(id -u)/com.chump.checkout-sync" 2>/dev/null \
        && echo "[drift-watchdog] kickstart issued" \
        || echo "[drift-watchdog] kickstart failed (daemon not loaded?)"
fi

exit 0
