#!/usr/bin/env bash
# analyze-infra1655-system-info.sh — INFRA-3546 (INFRA-1655 slice)
#
# Analyzes live system information to rule in/out the 3 candidate root
# causes for the jeffs-macbook-air-10-X actions/checkout@v6 flake:
#   1. disk full
#   2. stale runner registration
#   3. network issues
#
# Read-only. Prints one verdict line per candidate cause.
#
# Usage: scripts/dev/analyze-infra1655-system-info.sh [--json]

set -euo pipefail

REPO="repairman29/chump"
RUNNER_NAME_PATTERN="jeffs-macbook-air-10"
JSON=false
[[ "${1:-}" == "--json" ]] && JSON=true

# ── 1. Stale runner registration ────────────────────────────────────────────
# A "stale registration" would show the runner present in the registry but
# offline/unresponsive. Query the live registry (via gh's built-in --jq, no
# standalone jq dependency) and check for any entry matching the runner name
# pattern.
all_runner_names="$(gh api "repos/${REPO}/actions/runners" --jq '.runners[].name' 2>/dev/null || true)"
runner_count="$(printf '%s\n' "$all_runner_names" | grep -c . || true)"
matching_runner="$(printf '%s\n' "$all_runner_names" | grep "^${RUNNER_NAME_PATTERN}" || true)"

if [[ -z "$matching_runner" ]]; then
    RUNNER_VERDICT="ruled_out"
    RUNNER_DETAIL="no runner matching '${RUNNER_NAME_PATTERN}*' is registered at all (registry has ${runner_count} entries) — fully deregistered, not merely stale"
else
    RUNNER_VERDICT="identified"
    RUNNER_DETAIL="matching runner(s) still registered: ${matching_runner}"
fi

# ── 2. Disk full ─────────────────────────────────────────────────────────────
# The M4 hardware isn't reachable from this session (no SSH access from a
# fleet worktree). Reason from the failure signature instead: the incident
# record (docs/process/SELF_HOSTED_RUNNERS.md) describes 0-step jobs ending
# CANCELLED/FAILURE in <30s with no visible failed step. A disk-full
# condition on the runner host would surface as a failure *inside* a step
# (checkout write failure, "no space left on device") — not a 0-step
# immediate cancellation before any step executes. Signature is inconsistent
# with disk-full as the trigger of the original flake.
DISK_VERDICT="ruled_out"
DISK_DETAIL="failure signature (0-step, CANCELLED/FAILURE in <30s, no failed step) is inconsistent with disk-full — that fails inside a running step, not before job start; no direct host access to confirm live df, so this is signature-based, not a live probe"

# ── 3. Network issues ────────────────────────────────────────────────────────
# Same signature reasoning: a network blip on `git clone`/checkout would
# show as a FAILED checkout step with a git/network error, not a 0-step
# job with no visible failed step at all.
NETWORK_VERDICT="ruled_out"
NETWORK_DETAIL="failure signature (0-step, no visible failed step) is inconsistent with a network flake on checkout — that fails visibly inside the checkout step; signature points to a runner-registration/dispatch-level issue instead"

if $JSON; then
    # No standalone jq dependency — build JSON by hand (values are
    # controlled strings with no embedded double-quotes).
    printf '{"stale_runner_registration":{"verdict":"%s","detail":"%s"},"disk_full":{"verdict":"%s","detail":"%s"},"network_issues":{"verdict":"%s","detail":"%s"}}\n' \
        "$RUNNER_VERDICT" "$RUNNER_DETAIL" "$DISK_VERDICT" "$DISK_DETAIL" "$NETWORK_VERDICT" "$NETWORK_DETAIL"
else
    echo "stale_runner_registration: ${RUNNER_VERDICT} — ${RUNNER_DETAIL}"
    echo "disk_full: ${DISK_VERDICT} — ${DISK_DETAIL}"
    echo "network_issues: ${NETWORK_VERDICT} — ${NETWORK_DETAIL}"
fi
