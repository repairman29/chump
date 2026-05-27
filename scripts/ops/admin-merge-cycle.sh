#!/usr/bin/env bash
# scripts/ops/admin-merge-cycle.sh — INFRA-2041 (2026-05-27)
#
# Wraps the admin-merge cycle: drop required-status-checks rule → merge PR
# with --admin → restore ruleset. Reads checked-in snapshot JSON so the
# /tmp/ruleset-*.json GC-silent-fail class is eliminated.
#
# Usage:
#   scripts/ops/admin-merge-cycle.sh --pr <N> [--ruleset-id <ID>]
#
# Options:
#   --pr <N>            PR number to admin-merge (required)
#   --ruleset-id <ID>   Ruleset ID to cycle (default: 15133729)
#   --propagation-wait  Seconds to wait after drop for ruleset propagation (default: 8)
#   --dry-run           Print commands without executing
#   --repo <owner/repo> Override repo (default: auto from gh repo view)
#
# Environment:
#   CHUMP_ADMIN_MERGE_DRY_RUN=1     same as --dry-run
#   CHUMP_ADMIN_MERGE_REPO          same as --repo
#   CHUMP_AMBIENT_LOG               override ambient.jsonl path
#
# Exit codes:
#   0  PR merged and ruleset restored
#   1  usage error or non-critical failure
#   2  CRITICAL: PR merged but ruleset restore failed (requires operator action)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/ruleset-snapshots"
DROP_JSON="$SNAPSHOT_DIR/drop.json"
RESTORE_JSON="$SNAPSHOT_DIR/restore.json"

# Defaults
PR_NUM=""
RULESET_ID="15133729"
PROPAGATION_WAIT=8
DRY_RUN="${CHUMP_ADMIN_MERGE_DRY_RUN:-0}"
REPO="${CHUMP_ADMIN_MERGE_REPO:-}"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            PR_NUM="$2"; shift 2 ;;
        --ruleset-id)
            RULESET_ID="$2"; shift 2 ;;
        --propagation-wait)
            PROPAGATION_WAIT="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --repo)
            REPO="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -30 | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "[admin-merge-cycle] unknown argument: $1" >&2
            exit 1 ;;
    esac
done

# Validate required args
if [[ -z "$PR_NUM" ]]; then
    echo "[admin-merge-cycle] ERROR: --pr <N> is required" >&2
    echo "Usage: $0 --pr <N> [--ruleset-id <ID>]" >&2
    exit 1
fi

# Validate snapshot files exist
if [[ ! -f "$DROP_JSON" ]]; then
    echo "[admin-merge-cycle] ERROR: drop snapshot not found: $DROP_JSON" >&2
    exit 1
fi
if [[ ! -f "$RESTORE_JSON" ]]; then
    echo "[admin-merge-cycle] ERROR: restore snapshot not found: $RESTORE_JSON" >&2
    exit 1
fi

# Resolve repo if not set
if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
    if [[ -z "$REPO" ]]; then
        echo "[admin-merge-cycle] ERROR: could not determine repo; pass --repo <owner/repo>" >&2
        exit 1
    fi
fi

# Ambient log
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"admin_merge_cycle"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

_run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] $*" >&2
    else
        "$@"
    fi
}

echo "[admin-merge-cycle] repo=$REPO ruleset=$RULESET_ID pr=$PR_NUM propagation_wait=${PROPAGATION_WAIT}s" >&2
[[ "$DRY_RUN" == "1" ]] && echo "[admin-merge-cycle] DRY-RUN mode — no changes will be made" >&2

# Step 1: Drop required_status_checks by loading the drop snapshot
echo "[admin-merge-cycle] step 1/3: dropping required_status_checks rule via $DROP_JSON" >&2
_run gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input "$DROP_JSON" > /dev/null

# Step 2: Wait for propagation
echo "[admin-merge-cycle] step 2/3: waiting ${PROPAGATION_WAIT}s for ruleset propagation..." >&2
if [[ "$DRY_RUN" != "1" ]]; then
    sleep "$PROPAGATION_WAIT"
fi

# Step 3: Admin-merge the PR
echo "[admin-merge-cycle] step 3/3: merging PR #$PR_NUM with --admin --squash" >&2
MERGE_EXIT=0
_run gh pr merge "$PR_NUM" --squash --admin || MERGE_EXIT=$?

# Step 4: Restore ruleset regardless of merge outcome
echo "[admin-merge-cycle] step 4/4: restoring ruleset via $RESTORE_JSON" >&2
RESTORE_EXIT=0
_run gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input "$RESTORE_JSON" > /dev/null || RESTORE_EXIT=$?

if [[ "$RESTORE_EXIT" -ne 0 ]]; then
    echo "[admin-merge-cycle] CRITICAL: ruleset restore FAILED (exit $RESTORE_EXIT) — operator action required" >&2
    echo "[admin-merge-cycle] CRITICAL: manually PUT restore snapshot: $RESTORE_JSON" >&2
    echo "[admin-merge-cycle] CRITICAL: command: gh api -X PUT repos/$REPO/rulesets/$RULESET_ID --input $RESTORE_JSON" >&2
    _emit "admin_merge_cycle_restore_failed" \
        "\"pr\":\"$PR_NUM\"" \
        "\"ruleset_id\":\"$RULESET_ID\"" \
        "\"restore_json\":\"$RESTORE_JSON\"" \
        "\"severity\":\"CRITICAL\""
    exit 2
fi

if [[ "$MERGE_EXIT" -ne 0 ]]; then
    echo "[admin-merge-cycle] WARNING: merge of PR #$PR_NUM failed (exit $MERGE_EXIT) — ruleset was restored" >&2
    _emit "admin_merge_cycle_merge_failed" \
        "\"pr\":\"$PR_NUM\"" \
        "\"ruleset_id\":\"$RULESET_ID\"" \
        "\"merge_exit\":\"$MERGE_EXIT\""
    exit 1
fi

echo "[admin-merge-cycle] OK: PR #$PR_NUM merged and ruleset restored" >&2
_emit "admin_merge_cycle_ok" \
    "\"pr\":\"$PR_NUM\"" \
    "\"ruleset_id\":\"$RULESET_ID\""
