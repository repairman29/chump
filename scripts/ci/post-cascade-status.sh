#!/usr/bin/env bash
# post-cascade-status.sh — INFRA-5430 (INFRA-1861 slice)
#
# Posts a GitHub commit status summarizing which required-check shards were
# cascade-cancelled (or superseded) so the list is visible directly in the
# PR's checks list — no need to open the workflow run's logs to find out
# "why did that shard show cancelled" (INFRA-5430 AC1-3).
#
# Companion to the classification logic in ci.yml's `test` rollup job
# (INFRA-1002) and scripts/ci/test-rollup-cascade-cancel.sh, which produce
# the cascade_cancels / supersedure_cancels / real_failures lists this
# script renders into a human-readable status description.
#
# Usage:
#   post-cascade-status.sh --sha SHA --repo OWNER/REPO \
#       [--cascade-cancels "job1,job2"] \
#       [--supersedure-cancels "job3,job4"] \
#       [--real-failures "job5"] \
#       [--dry-run] [--ambient-log PATH]
#
# --dry-run prints the computed description and skips the `gh api` call
# (and the --sha/--repo requirement) — used by the test suite.
#
# No-op (exit 0, nothing posted) when both cascade-cancels and
# supersedure-cancels are empty — there is nothing to explain.
#
# Emits kind=cascade_status_posted to ambient.jsonl on a live post
# (best-effort; never fails the run if the log can't be written).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/../.." && pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

SHA=""
REPO=""
CASCADE_CANCELS=""
SUPERSEDURE_CANCELS=""
REAL_FAILURES=""
DRY_RUN=0

usage() { grep '^#' "$0" | sed 's/^# \?//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)                  SHA="$2"; shift 2 ;;
        --repo)                 REPO="$2"; shift 2 ;;
        --cascade-cancels)      CASCADE_CANCELS="$2"; shift 2 ;;
        --supersedure-cancels)  SUPERSEDURE_CANCELS="$2"; shift 2 ;;
        --real-failures)        REAL_FAILURES="$2"; shift 2 ;;
        --dry-run)               DRY_RUN=1; shift ;;
        --ambient-log)           AMBIENT_LOG="$2"; shift 2 ;;
        -h|--help)               usage; exit 0 ;;
        *) echo "[post-cascade-status] unknown arg: $1" >&2; exit 3 ;;
    esac
done

if [[ -z "$CASCADE_CANCELS" && -z "$SUPERSEDURE_CANCELS" ]]; then
    echo "[post-cascade-status] no cancelled jobs to report — skipping"
    exit 0
fi

build_description() {
    local desc=""
    if [[ -n "$CASCADE_CANCELS" ]]; then
        local cause="a sibling failure"
        [[ -n "$REAL_FAILURES" ]] && cause="${REAL_FAILURES//,/, }"
        desc="Cancelled (caused by ${cause}): ${CASCADE_CANCELS//,/, }"
    fi
    if [[ -n "$SUPERSEDURE_CANCELS" ]]; then
        local sup="Cancelled (superseded by a newer run): ${SUPERSEDURE_CANCELS//,/, }"
        desc="${desc:+$desc; }$sup"
    fi
    # GitHub commit-status description is capped at 140 chars.
    if [[ ${#desc} -gt 140 ]]; then
        desc="${desc:0:137}..."
    fi
    printf '%s' "$desc"
}

DESCRIPTION="$(build_description)"
echo "[post-cascade-status] description: $DESCRIPTION"

if [[ "$DRY_RUN" -eq 1 ]]; then
    exit 0
fi

if [[ -z "$SHA" ]]; then
    echo "[post-cascade-status] ERROR: --sha required for a live post" >&2
    exit 3
fi
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
    echo "[post-cascade-status] ERROR: --repo or \$GITHUB_REPOSITORY required for a live post" >&2
    exit 3
fi

gh api "repos/${REPO}/statuses/${SHA}" \
    -f state=success \
    -f context="cascade-cancellation" \
    -f description="$DESCRIPTION" \
    >/dev/null

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
esc_desc="${DESCRIPTION//\\/\\\\}"
esc_desc="${esc_desc//\"/\\\"}"
# scanner-anchor: "kind":"cascade_status_posted"
printf '{"ts":"%s","kind":"cascade_status_posted","sha":"%s","description":"%s"}\n' \
    "$ts" "$SHA" "$esc_desc" >> "$AMBIENT_LOG" 2>/dev/null || true
