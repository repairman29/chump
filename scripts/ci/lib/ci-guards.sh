#!/usr/bin/env bash
# scripts/ci/lib/ci-guards.sh — RESILIENT-018
#
# Guard helper for any scripts/ci/test-*.sh that calls `gh api` or `gh pr ...`.
# Precedent (INFRA-1846): e2e-pwa failed persistently because
# chump::github_rate_limit called `gh api rate_limit` from inside a workflow
# that doesn't set GH_TOKEN — a hard-fail on missing credentials rather than
# a graceful skip. This helper makes "no token" a WARN-and-skip, not a
# CI-red, for any script that sources it.
#
# Usage (single line, before the first `gh api`/`gh pr` call):
#   source "$(dirname "$0")/lib/ci-guards.sh"
#   check_gh_token_or_skip
#
# check_gh_token_or_skip:
#   - GH_TOKEN or GITHUB_TOKEN set  -> returns 0, script continues normally.
#   - neither set                   -> prints a WARN, emits ambient
#                                       kind=ci_gh_token_missing_skip, and
#                                       exits the CALLING SCRIPT with 0
#                                       (pass-with-WARN, not a CI failure).

check_gh_token_or_skip() {
  if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
    return 0
  fi

  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-$0}")"

  echo "[ci-guards] WARN: GH_TOKEN/GITHUB_TOKEN not set — skipping gh api/gh pr call in $script_name (RESILIENT-018)" >&2

  if command -v chump >/dev/null 2>&1; then
    # scanner-anchor: "kind":"ci_gh_token_missing_skip"
    chump ambient emit ci_gh_token_missing_skip \
      --source "$script_name" \
      --field workflow_name="${GITHUB_WORKFLOW:-unknown}" \
      --field job_name="${GITHUB_JOB:-unknown}" \
      --field script="$script_name" >/dev/null 2>&1 || true
  fi

  exit 0
}
