#!/usr/bin/env bash
# ghost-gap-reaper.sh — INFRA-556: roll back gaps that are status=done but
# whose closed_pr was closed without merging (CI failed forever / operator
# closed the PR). Prevents ghost gaps from clogging the registry.
#
# Run periodically from control.sh (every 5 min). Also safe to run manually.
# Best-effort: errors are printed but never block the caller.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

_chump="${HOME}/.cargo/bin/chump"
command -v "$_chump" >/dev/null 2>&1 || _chump="chump"
command -v "$_chump" >/dev/null 2>&1 || { echo "[ghost-gap-reaper] chump not found, skipping"; exit 0; }
command -v gh       >/dev/null 2>&1 || { echo "[ghost-gap-reaper] gh not found, skipping"; exit 0; }

_gaps_json=$(CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
    "$_chump" gap list --status done --json 2>/dev/null || echo "[]")

[[ "$_gaps_json" == "[]" ]] || [[ -z "$_gaps_json" ]] && exit 0

_rolled_back=0

while IFS= read -r _entry; do
    [[ -z "$_entry" ]] && continue
    _gid=$(printf '%s' "$_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    _pr=$(printf '%s' "$_entry"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('closed_pr') or '')" 2>/dev/null || true)
    [[ -z "$_gid" || -z "$_pr" ]] && continue

    _pr_info=$(gh pr view "$_pr" --json state,mergedAt 2>/dev/null || echo "")
    [[ -z "$_pr_info" ]] && continue

    _state=$(printf '%s' "$_pr_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null || true)
    _merged=$(printf '%s' "$_pr_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergedAt') or '')" 2>/dev/null || true)

    # MERGED → correctly done; OPEN → CI still running, check next cycle; CLOSED without merge → ghost
    [[ "$_state" == "MERGED" ]] && continue
    [[ "$_state" == "OPEN"   ]] && continue
    [[ "$_state" == "CLOSED" && -n "$_merged" ]] && continue  # closed after merge (shouldn't happen but guard it)

    if [[ "$_state" == "CLOSED" && -z "$_merged" ]]; then
        echo "[ghost-gap-reaper] INFRA-556: rolling back $_gid — PR #$_pr closed without merge"
        CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
            "$_chump" gap set "$_gid" --status open 2>/dev/null || {
            echo "[ghost-gap-reaper] WARNING: failed to roll back $_gid"
            continue
        }
        if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
            "$REPO_ROOT/scripts/dev/ambient-emit.sh" gap_rolled_back \
                "gap=$_gid" "pr=$_pr" "reason=pr_closed_without_merge" 2>/dev/null || true
        fi
        (( _rolled_back++ )) || true
    fi
done < <(printf '%s' "$_gaps_json" | python3 -c "
import json, sys
for g in json.load(sys.stdin):
    print(json.dumps(g))
" 2>/dev/null || true)

(( _rolled_back > 0 )) && echo "[ghost-gap-reaper] rolled back $_rolled_back ghost gap(s) to status=open"
exit 0
