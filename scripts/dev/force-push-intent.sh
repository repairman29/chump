#!/usr/bin/env bash
# scripts/dev/force-push-intent.sh — INFRA-1971
#
# Signal to the pr-auto-rearm daemon that a force-push is INTENTIONAL.
# Writes a marker file at .chump-locks/force-push-intent-<branch_safe>.json
# with a 60-second TTL. The daemon will skip re-evaluation of this PR's
# auto-merge state during the grace window, preventing the spurious CLOSED
# flash observed in PRs #2561 and #2566 on 2026-05-24/25.
#
# Usage:
#   bash scripts/dev/force-push-intent.sh [<branch>]
#
#   If <branch> is omitted, uses the current git branch.
#   Run this BEFORE the force-push. The 60s window starts immediately.
#
# Idempotent: re-running refreshes the mtime (extends the window).
#
# Example workflow:
#   bash scripts/dev/force-push-intent.sh
#   git push --force-with-lease origin HEAD

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCKS_DIR="$REPO_ROOT/.chump-locks"
TTL_SECS=60

# Determine branch
if [[ "${1:-}" != "" ]]; then
    BRANCH="$1"
else
    BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

if [[ -z "$BRANCH" || "$BRANCH" == "HEAD" ]]; then
    echo "[force-push-intent] ERROR: could not determine branch name. Pass it explicitly: $0 <branch>" >&2
    exit 1
fi

# Sanitize branch name for use in filename (replace / with _)
BRANCH_SAFE="${BRANCH//\//_}"
INTENT_FILE="$LOCKS_DIR/force-push-intent-${BRANCH_SAFE}.json"

mkdir -p "$LOCKS_DIR"

# Determine operator identity (session ID or username fallback)
OPERATOR_ID="${CHUMP_SESSION_ID:-${USER:-unknown}}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Write the intent file (idempotent — touch updates mtime on re-run)
printf '{"operator_id":"%s","ts":"%s","branch":"%s","ttl_secs":%d}\n' \
    "$OPERATOR_ID" "$TS" "$BRANCH" "$TTL_SECS" > "$INTENT_FILE"

echo "[force-push-intent] intent recorded for branch '$BRANCH'"
echo "[force-push-intent] grace window: ${TTL_SECS}s from now (file: $INTENT_FILE)"
echo "[force-push-intent] pr-auto-rearm will defer re-evaluation during this window"
echo "[force-push-intent] proceed with your force-push now."
