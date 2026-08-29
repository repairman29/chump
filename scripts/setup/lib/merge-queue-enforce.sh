#!/usr/bin/env bash
# merge-queue-enforce.sh — INFRA-1518
#
# Enforces that GitHub Merge Queue stays enabled on `main`'s branch-protection
# rule. This is the setup-invariant closing INFRA-1377's "operator flips the
# switch by hand after every fleet up" gap — once wired into
# chump-fleet-bootstrap.sh, the CONVOY pattern (bot-merge racing multiple PRs
# onto main without a queue) becomes structurally impossible on any bootstrapped
# host.
#
# Sourced by scripts/setup/chump-fleet-bootstrap.sh and directly by
# scripts/ci/test-bootstrap-merge-queue-enforce.sh (with a stubbed `gh`).
#
# merge_queue_enforce <mode> <repo> [branch]
#   mode:   "check"   — read-only; exit 1 if disabled
#           anything else — install mode; PUT the rule if disabled
#   repo:   owner/name
#   branch: protected branch (default: main)
#
# Exit codes:
#   0  already enabled (either mode), or successfully enabled (install mode)
#   1  disabled in check mode, or the PUT failed in install mode

merge_queue_enforce() {
    local mode="$1"
    local repo="$2"
    local branch="${3:-main}"

    local enabled
    enabled="$(gh api "repos/${repo}/branches/${branch}/protection" \
        --jq '.required_pull_request_reviews.merge_queue.enabled // false' 2>/dev/null || echo "false")"

    if [[ "$enabled" == "true" ]]; then
        echo "[merge-queue-enforce] ok — Merge Queue already enabled on ${repo}:${branch}"
        return 0
    fi

    if [[ "$mode" == "check" ]]; then
        echo "[merge-queue-enforce] MISSING — Merge Queue disabled on ${repo}:${branch}. Run: bash scripts/setup/chump-fleet-bootstrap.sh" >&2
        return 1
    fi

    echo "[merge-queue-enforce] enabling Merge Queue on ${repo}:${branch} ..."
    local body
    body="$(cat <<'EOF'
{
  "required_pull_request_reviews": {
    "merge_queue": {
      "enabled": true,
      "grouping_strategy": "ALLGREEN",
      "merge_method": "SQUASH",
      "max_entries_to_build": 5,
      "max_entries_to_merge": 5,
      "min_entries_to_merge": 1,
      "min_entries_to_merge_wait_minutes": 1
    }
  }
}
EOF
)"
    if printf '%s' "$body" | gh api --method PUT "repos/${repo}/branches/${branch}/protection" --input - >/dev/null 2>&1; then
        echo "[merge-queue-enforce] enabled Merge Queue on ${repo}:${branch}"
        return 0
    fi

    echo "[merge-queue-enforce] FAILED to enable Merge Queue on ${repo}:${branch}" >&2
    return 1
}
