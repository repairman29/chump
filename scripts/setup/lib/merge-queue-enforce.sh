#!/usr/bin/env bash
# scripts/setup/lib/merge-queue-enforce.sh — INFRA-1518
#
# Ensures GitHub Merge Queue stays enabled on main so every
# `chump-fleet-bootstrap.sh` run structurally forecloses the CONVOY-thrash
# pattern (INFRA-1377) instead of relying on an operator to flip a web-UI
# switch once and hope it stays flipped.
#
# Exposes one function: enforce_merge_queue "$MODE" "$REPO_ROOT"
#   MODE=check   → exit 1 with an actionable message if disabled, no mutation
#   MODE=install → PUT the protection rule when disabled; no-op when enabled
#
# Sourced by scripts/setup/chump-fleet-bootstrap.sh. Also sourced directly by
# scripts/ci/test-bootstrap-merge-queue-enforce.sh with a stubbed `gh` on PATH.

enforce_merge_queue() {
    local mode="$1" repo_root="$2"

    if ! command -v gh >/dev/null 2>&1; then
        echo "[bootstrap] gh CLI not available — skipping merge-queue enforcement" >&2
        return 0
    fi

    local remote_url owner_repo owner repo_name
    remote_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
    owner_repo="$(echo "$remote_url" | sed 's|.*github.com[:/]||; s|\.git$||')"
    owner="${owner_repo%%/*}"
    repo_name="${owner_repo##*/}"

    if [[ -z "$remote_url" || -z "$owner" || -z "$repo_name" ]]; then
        echo "[bootstrap] cannot determine owner/repo from origin remote — skipping merge-queue enforcement" >&2
        return 0
    fi

    local enabled
    enabled="$(gh api "repos/${owner}/${repo_name}/branches/main/protection" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("false")
    sys.exit(0)
mq = d.get("required_pull_request_reviews", {}).get("merge_queue", {})
print("true" if mq.get("enabled") else "false")
' 2>/dev/null)"
    [[ -z "$enabled" ]] && enabled="false"

    if [[ "$enabled" == "true" ]]; then
        [[ "$mode" == "check" ]] && echo "  ok      merge-queue"
        return 0
    fi

    if [[ "$mode" == "check" ]]; then
        echo "  MISSING merge-queue  (Merge Queue is not enabled on ${owner}/${repo_name}:main)"
        echo "Merge Queue is not enabled on ${owner}/${repo_name}:main — run: bash scripts/setup/chump-fleet-bootstrap.sh" >&2
        echo "  (or enable manually: https://github.com/${owner}/${repo_name}/settings/branches)" >&2
        return 1
    fi

    echo "[bootstrap] enabling Merge Queue on ${owner}/${repo_name}:main"
    if gh api --method PUT "repos/${owner}/${repo_name}/branches/main/protection" \
        -f "required_pull_request_reviews[merge_queue][enabled]=true" \
        -f "required_pull_request_reviews[merge_queue][grouping_strategy]=ALLGREEN" \
        -f "required_pull_request_reviews[merge_queue][merge_method]=SQUASH" \
        -F "required_pull_request_reviews[merge_queue][max_entries_to_build]=5" \
        -F "required_pull_request_reviews[merge_queue][max_entries_to_merge]=5" \
        -F "required_pull_request_reviews[merge_queue][min_entries_to_merge]=1" \
        -F "required_pull_request_reviews[merge_queue][min_entries_to_merge_wait_minutes]=1" \
        >/dev/null 2>&1; then
        return 0
    else
        local rc=$?
        echo "[bootstrap] FAILED to enable merge-queue on ${owner}/${repo_name}:main (rc=$rc)" >&2
        return "$rc"
    fi
}
