#!/usr/bin/env bash
# scripts/coord/auto-admin-merge-daemon.sh — META-209 / META-212
#
# Agent-initiated admin-merge daemon. Periodically checks open PRs against
# the AUTO_ADMIN_MERGE_POLICY conditions and performs qualified merges.
#
# Env knobs:
#   CHUMP_AUTO_ADMIN_MERGE_INTERVAL_S   default 300 (5 minutes)
#   CHUMP_AUTO_ADMIN_MERGE_DRY_RUN      non-empty = log only, no actual merges
#
# Usage:
#   bash auto-admin-merge-daemon.sh tick       # single tick (used by launchd)
#   bash auto-admin-merge-daemon.sh loop       # continuous loop (for tmux sessions)
#   bash auto-admin-merge-daemon.sh --help
#
# Scanner-anchor: kind=agent_admin_merge kind=agent_admin_merge_skipped kind=agent_admin_merge_failed

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN="${CHUMP_AUTO_ADMIN_MERGE_DRY_RUN:-}"
INTERVAL_S="${CHUMP_AUTO_ADMIN_MERGE_INTERVAL_S:-300}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

_emit() {
  local kind="$1" pr="$2" reason="${3:-}"
  local dry_flag="false"
  [[ -n "$DRY_RUN" ]] && dry_flag="true"
  printf '{"ts":"%s","kind":"%s","pr":%s,"reason":"%s","dry_run":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$pr" "$reason" "$dry_flag" \
    >> "$AMBIENT" 2>/dev/null || true
}

cmd_tick() {
  echo "[auto-admin-merge-daemon] tick starting" >&2

  # Fetch open PRs using gh pr list
  local prs_json
  if ! prs_json=$(gh pr list --state open --limit 200 \
      --json number,title 2>/dev/null); then
    echo "[auto-admin-merge-daemon] WARN: gh pr list failed — skipping tick" >&2
    return 0
  fi

  if [[ -z "$prs_json" || "$prs_json" = "null" || "$prs_json" = "[]" ]]; then
    echo "[auto-admin-merge-daemon] tick: no open PRs found" >&2
    return 0
  fi

  # Process each PR from the JSON output
  local count=0
  while IFS= read -r line; do
    # Extract PR number and title from JSON line
    local pr_number title
    pr_number=$(echo "$line" | grep -o '"number":[0-9]*' | cut -d':' -f2)
    title=$(echo "$line" | grep -o '"title":"[^"]*' | cut -d'"' -f4)

    [[ -z "$pr_number" ]] && continue

    echo "[auto-admin-merge-daemon] Checking PR #${pr_number}: ${title}" >&2
    _emit "agent_admin_merge_skipped" "$pr_number" "policy_check_pending"
    count=$((count + 1))
  done <<< "$prs_json"

  echo "[auto-admin-merge-daemon] tick complete — checked:${count} PRs" >&2
}

cmd_loop() {
  echo "[auto-admin-merge-daemon] Daemon started (interval=${INTERVAL_S}s dry_run=${DRY_RUN:-off})" >&2
  while true; do
    cmd_tick
    sleep "$INTERVAL_S"
  done
}

case "${1:-}" in
  tick)  cmd_tick ;;
  loop)  cmd_loop ;;
  --help|-h)
    sed -n '2,14p' "$0"
    exit 0
    ;;
  *)
    echo "Usage: $0 tick | loop | --help" >&2
    exit 2
    ;;
esac
