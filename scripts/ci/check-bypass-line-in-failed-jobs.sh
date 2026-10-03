#!/usr/bin/env bash
# check-bypass-line-in-failed-jobs.sh — INFRA-4537 (INFRA-1861 slice)
#
# Dynamic sibling of INFRA-5429 (scripts/ci/test-bypass-line-required.sh).
# INFRA-5429 statically greps each gate-manifest.yaml check script's SOURCE
# for a bypass line. This script instead scans the ACTUAL RUNTIME OUTPUT
# (the GitHub Actions job log) of every required same-workflow lane that
# failed on *this* run — so a gate whose bypass line is only emitted on a
# runtime-computed branch (or that isn't registered in gate-manifest.yaml
# yet) is still caught.
#
# AC (INFRA-4537):
#   1. Scans the output of every required check that exits with FAIL.
#   2. Fails if that output has no line starting with "How to bypass cleanly:"
#   3. Passes when every failing check's output has the line.
#
# Usage (real invocation, from the `verified` job in .github/workflows/ci.yml):
#   GH_TOKEN=... GH_REPO=owner/repo GITHUB_RUN_ID=123 \
#     bash scripts/ci/check-bypass-line-in-failed-jobs.sh \
#       --lane "fast-checks=success" --lane "clippy=failure" ...
#
# Self-test mode (no network — exercised by
# scripts/ci/test-bypass-line-in-failed-jobs.sh): set
# CHUMP_FAILED_JOB_LOG_FIXTURE_DIR to a directory containing "<job name>.log"
# files; the script reads logs from there instead of calling `gh api`.
#
# Limitation: cross-workflow lanes (audit, ACP-smoke) live in a different
# workflow run than this one; their pass/fail status is already polled via
# scripts/ci/poll-cross-workflow-checks.sh, but fetching their logs needs a
# separate run-id lookup. Out of scope for this slice — not passed as
# --lane args by the caller.
#
# Exit: 0 = clean (or nothing to check), 1 = one or more failed lanes have
# no bypass line in their output.

set -uo pipefail

BYPASS_PATTERN="How to bypass cleanly:"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

LANES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lane)
            LANES+=("$2")
            shift 2
            ;;
        *)
            fail "unknown argument: $1"
            exit 2
            ;;
    esac
done

fetch_job_log() {
    local job_name="$1"

    if [[ -n "${CHUMP_FAILED_JOB_LOG_FIXTURE_DIR:-}" ]]; then
        local fixture="${CHUMP_FAILED_JOB_LOG_FIXTURE_DIR}/${job_name}.log"
        if [[ -f "$fixture" ]]; then
            cat "$fixture"
        fi
        return 0
    fi

    if [[ -z "${GITHUB_RUN_ID:-}" || -z "${GH_REPO:-}" ]]; then
        fail "GITHUB_RUN_ID / GH_REPO not set — cannot fetch job log for '$job_name'"
        return 1
    fi

    local job_id
    job_id="$(gh api "repos/${GH_REPO}/actions/runs/${GITHUB_RUN_ID}/jobs" --paginate \
        --jq ".jobs[] | select(.name==\"${job_name}\") | .id" 2>/dev/null | head -1)"

    if [[ -z "$job_id" ]]; then
        fail "no job named '$job_name' found in run ${GITHUB_RUN_ID}"
        return 1
    fi

    gh api "repos/${GH_REPO}/actions/runs/${GITHUB_RUN_ID}/jobs/${job_id}/logs" 2>/dev/null
}

VIOLATIONS=0
CHECKED=0

for lane in "${LANES[@]}"; do
    name="${lane%%=*}"
    result="${lane#*=}"

    if [[ "$result" != "failure" ]]; then
        continue
    fi

    CHECKED=$((CHECKED + 1))
    log="$(fetch_job_log "$name")"

    if [[ -z "$log" ]]; then
        fail "$name: failed lane but could not retrieve its log output"
        VIOLATIONS=$((VIOLATIONS + 1))
        continue
    fi

    if grep -qF "$BYPASS_PATTERN" <<<"$log"; then
        pass "$name: failed lane output includes a '$BYPASS_PATTERN' line"
    else
        fail "$name: failed lane output has no '$BYPASS_PATTERN' line"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

echo ""
if [[ "$CHECKED" -eq 0 ]]; then
    info "INFRA-4537: no failed lanes to check this run."
    exit 0
fi

if [[ "$VIOLATIONS" -eq 0 ]]; then
    echo "INFRA-4537: all $CHECKED failed lane(s) carry a bypass line in their output."
    exit 0
else
    fail "INFRA-4537: $VIOLATIONS of $CHECKED failed lane(s) missing a '$BYPASS_PATTERN' line."
    fail "How to bypass cleanly: add a line 'How to bypass cleanly: <instructions>' to the flagged check's FAIL-path output (see scripts/ci/check-pr-scope.sh for the pattern)."
    exit 1
fi
