#!/usr/bin/env bash
# RESILIENT-1552 (child of RESILIENT-1548): emit kind=ci_wall_clock with the
# total wall-clock from the `changes` job's start (first job on every
# ci.yml trigger) to this `verified` job's completion (last job), keyed by
# PR class, so the parent's "median PR CI wall-clock dropped" claim is
# verifiable off a signal instead of asserted.
#
# Advisory only — `if: always()` + this script never exits non-zero, so it
# can never gate or block a PR (AC4).
set -uo pipefail

JOB_START_TS="${JOB_START_TS:-}"
DOCS_ONLY="${DOCS_ONLY:-false}"
SCRIPTS_ONLY="${SCRIPTS_ONLY:-false}"
PR_NUMBER="${PR_NUMBER:-}"

if [[ -z "$JOB_START_TS" || ! "$JOB_START_TS" =~ ^[0-9]+$ ]]; then
    echo "[emit-ci-wall-clock] no valid job_start_ts — skipping (not fatal)." >&2
    exit 0
fi

NOW="$(date -u +%s)"
DURATION_S=$(( NOW - JOB_START_TS ))
[[ "$DURATION_S" -lt 0 ]] && DURATION_S=0

# PR class: mirrors the dorny/paths-filter lane flags computed by the
# `changes` job. docs-only / scripts-only (no Rust) / full (touches crates).
PR_CLASS="full"
if [[ "$DOCS_ONLY" == "true" ]]; then
    PR_CLASS="docs-only"
elif [[ "$SCRIPTS_ONLY" == "true" ]]; then
    PR_CLASS="scripts-only"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LINE=$(printf '{"ts":"%s","kind":"ci_wall_clock","pr_number":"%s","pr_class":"%s","duration_s":%s}' \
    "$TS" "$PR_NUMBER" "$PR_CLASS" "$DURATION_S")

echo "$LINE"
echo "### CI wall-clock (RESILIENT-1552)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
echo "pr_class=\`${PR_CLASS}\` duration_s=\`${DURATION_S}\` pr=#${PR_NUMBER}" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true

if [[ -n "${CHUMP_AMBIENT_INGEST_URL:-}" ]]; then
    curl -fsS -X POST -H 'Content-Type: application/json' -d "$LINE" "$CHUMP_AMBIENT_INGEST_URL" \
        || echo "warning: failed to POST ci_wall_clock to $CHUMP_AMBIENT_INGEST_URL" >&2
else
    STATS_DIR="${RUNNER_TEMP:-/tmp}/chump-runner-stats"
    mkdir -p "$STATS_DIR" 2>/dev/null || true
    echo "$LINE" >> "$STATS_DIR/ci_wall_clock.jsonl" 2>/dev/null || true
fi

exit 0
