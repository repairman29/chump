#!/usr/bin/env bash
# ghost-gap-reaper.sh — INFRA-556: roll back gaps that are status=done but
# whose closed_pr was closed without merging (CI failed forever / operator
# closed the PR). Prevents ghost gaps from clogging the registry.
#
# INFRA-1284: Rewired to batch REST approach — one REST page scan replaces
# one per-gap REST call (1576+ done gaps → was O(N) calls, now O(1) call).
#
# Strategy:
#   1. GET /pulls?state=closed&per_page=100 via REST (one call, no GraphQL).
#   2. Filter to merged_at==null within lookback window → bounced PR numbers.
#   3. Build closed_pr→gap_id map from done gaps in state.db (no API calls).
#   4. Intersect: any done gap whose closed_pr appears in the bounced set → ghost.
#   5. Roll those gaps back to open + emit ambient event.
#
# Run periodically from control.sh (every 5 min) or via launchd. Best-effort.
#
# Env:
#   CHUMP_GHOST_REAPER_LOOKBACK_DAYS   Days of closed PRs to scan (default 7)
#   CHUMP_GHOST_REAPER=0               Disable entirely

set -uo pipefail

[[ "${CHUMP_GHOST_REAPER:-1}" == "0" ]] && exit 0

# INFRA-956: default harness to a schema-valid value.
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_LOOKBACK_DAYS="${CHUMP_GHOST_REAPER_LOOKBACK_DAYS:-7}"

_chump="${HOME}/.cargo/bin/chump"
command -v "$_chump" >/dev/null 2>&1 || _chump="chump"
command -v "$_chump" >/dev/null 2>&1 || { echo "[ghost-gap-reaper] chump not found, skipping"; exit 0; }
command -v gh       >/dev/null 2>&1 || { echo "[ghost-gap-reaper] gh not found, skipping"; exit 0; }
command -v python3  >/dev/null 2>&1 || { echo "[ghost-gap-reaper] python3 not found, skipping"; exit 0; }

_repo="${GITHUB_REPOSITORY:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')}"

# ── Step 1: one REST call — recently-closed PRs ───────────────────────────────
_closed_prs=$(gh api "repos/$_repo/pulls?state=closed&per_page=100&sort=updated&direction=desc" \
    2>/dev/null || echo "[]")

[[ -z "$_closed_prs" || "$_closed_prs" == "[]" ]] && exit 0

# ── Step 2: filter to closed-without-merge within lookback window ─────────────
# Write JSON to a temp file to avoid shell-quoting issues with large payloads.
_tmp_prs=$(mktemp /tmp/ghost-reaper-prs.XXXXXX)
printf '%s' "$_closed_prs" > "$_tmp_prs"
_bounced_pr_nums=$(python3 -c "
import json, sys, datetime
lookback_days = $_LOOKBACK_DAYS
cutoff = datetime.datetime.utcnow() - datetime.timedelta(days=lookback_days)
with open('$_tmp_prs') as f:
    prs = json.load(f)
for pr in prs:
    if pr.get('merged_at') is not None:
        continue
    if pr.get('state') != 'closed':
        continue
    ts_str = pr.get('updated_at') or pr.get('closed_at') or ''
    if ts_str:
        try:
            ts = datetime.datetime.fromisoformat(ts_str.replace('Z','+00:00')).replace(tzinfo=None)
            if ts < cutoff:
                continue
        except Exception:
            pass
    print(pr['number'])
" 2>/dev/null || true)
rm -f "$_tmp_prs"

[[ -z "$_bounced_pr_nums" ]] && exit 0

# ── Step 3: build closed_pr→gap_id map from state.db (no API calls) ──────────
_done_json=$(CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
    "$_chump" gap list --status done --json 2>/dev/null || echo "[]")

[[ "$_done_json" == "[]" || -z "$_done_json" ]] && exit 0

_pr_to_gap=$(printf '%s' "$_done_json" | python3 -c "
import json, sys
m = {}
for g in json.load(sys.stdin):
    pr = g.get('closed_pr')
    if pr:
        m[str(pr)] = g['id']
print(json.dumps(m))
" 2>/dev/null || echo "{}")

# ── Step 4: intersect in one Python call — no per-PR spawning ────────────────
# Write both inputs to temp files to avoid shell-quoting issues.
_tmp_map=$(mktemp /tmp/ghost-reaper-map.XXXXXX)
_tmp_prnums=$(mktemp /tmp/ghost-reaper-nums.XXXXXX)
printf '%s' "$_pr_to_gap"   > "$_tmp_map"
printf '%s' "$_bounced_pr_nums" > "$_tmp_prnums"

# Emit one "GAP_ID PR_NUM" line per ghost found.
_ghosts=$(python3 -c "
import json
with open('$_tmp_map') as f:
    pr_to_gap = json.load(f)
with open('$_tmp_prnums') as f:
    bounced = [ln.strip() for ln in f if ln.strip()]
for pr_num in bounced:
    gap_id = pr_to_gap.get(str(pr_num), '')
    if gap_id:
        print(gap_id, pr_num)
" 2>/dev/null || true)

rm -f "$_tmp_map" "$_tmp_prnums"

_rolled_back=0

while IFS=' ' read -r _gid _pr_num; do
    [[ -z "$_gid" ]] && continue

    echo "[ghost-gap-reaper] INFRA-556: rolling back $_gid — PR #$_pr_num closed without merge"
    CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 CHUMP_ALLOW_RECYCLE=1 \
        "$_chump" gap set "$_gid" --status open 2>/dev/null || {
        echo "[ghost-gap-reaper] WARNING: failed to roll back $_gid"
        continue
    }
    if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" gap_rolled_back \
            "gap=$_gid" "pr=$_pr_num" "reason=pr_closed_without_merge" 2>/dev/null || true
    fi
    (( _rolled_back++ )) || true

done <<< "$_ghosts"

(( _rolled_back > 0 )) && echo "[ghost-gap-reaper] rolled back $_rolled_back ghost gap(s) to status=open"
exit 0
