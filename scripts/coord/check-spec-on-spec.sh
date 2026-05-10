#!/usr/bin/env bash
# check-spec-on-spec.sh — INFRA-684: guard against two speculative agents
# both reaching the auto-merge arm stage for the same gap.
#
# When two sessions race with --speculative, the INFRA-193 loser sweep closes
# the loser PR AFTER the winner arms. But if both reach the arm step before
# either sweep runs, two PRs can get auto-merge enabled simultaneously and
# both could land — or the second one conflicts after the first squash-merges.
#
# This guard checks BEFORE arming: if another open PR for the same gap already
# has auto-merge enabled, this arm must abort.
#
# Usage:
#   bash check-spec-on-spec.sh <GAP-ID> <OWN-PR-NUMBER>
#
# Exit codes:
#   0 — safe to arm (no competing armed PR found)
#   1 — BLOCKED: another PR for this gap is already armed
#   2 — usage error

set -uo pipefail

GAP_ID="${1:-}"
OWN_PR="${2:-}"

if [[ -z "$GAP_ID" || -z "$OWN_PR" ]]; then
    echo "Usage: $0 <GAP-ID> <OWN-PR-NUMBER>" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[check-spec-on-spec] SKIP: gh CLI not available" >&2
    exit 0
fi

# Query open PRs for this gap that have autoMergeRequest set (armed).
# Exclude our own PR (OWN_PR) to avoid false-positive self-detection.
# Note: pipe through jq (not --jq) so stub gh binaries in tests work correctly.
armed=$(gh pr list --state open --search "$GAP_ID in:title" \
    --json number,headRefName,autoMergeRequest \
    2>/dev/null \
    | jq -r ".[] | select(.number != $OWN_PR and .autoMergeRequest != null) | \"\(.number)|\(.headRefName)\"" \
    2>/dev/null | head -1 || true)

if [[ -n "$armed" ]]; then
    armed_num="${armed%%|*}"
    armed_branch="${armed##*|}"
    echo "[check-spec-on-spec] BLOCKED: PR #$armed_num ($armed_branch) is already armed for" >&2
    echo "  auto-merge on $GAP_ID. The speculative race is decided — this arm must not proceed." >&2
    echo "  PR #$armed_num wins. Wait for it to land (or be closed), then re-evaluate." >&2
    echo "  If PR #$armed_num was abandoned, bypass: CHUMP_SPEC_ON_SPEC_CHECK=0" >&2
    exit 1
fi

echo "[check-spec-on-spec] OK: no competing armed PR found for $GAP_ID (own PR #$OWN_PR excluded)."
