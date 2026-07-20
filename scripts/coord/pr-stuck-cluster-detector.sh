#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: lib/ dynamic sources; SC2034: vars used via printf/emission patterns
# scripts/coord/pr-stuck-cluster-detector.sh — INFRA-1133
#
# Detect PR stuck clusters: when 3+ distinct PRs get stuck (merged but unmerged)
# simultaneously within a 2h window. Indicates systemic blockage (CI flake, rate
# limit, human forget, rebase conflict storm).
#
# Cluster detected → file INFRA-NEW-PR-STUCK-CLUSTER gap with priority:P0.
#
# Dedup: each cluster has a stamp file under .chump-locks/.cluster-sent/<cluster_id>.ts.
# Refuse to re-file within CHUMP_PR_CLUSTER_RESEND_COOLDOWN_S (default 24h).
#
# Usage:
#   scripts/coord/pr-stuck-cluster-detector.sh             # dry-run
#   scripts/coord/pr-stuck-cluster-detector.sh --apply     # file gap
#
# Cron-friendly. Emits kind=pr_stuck_cluster ambient events.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# Allow external override of LOCK_DIR for testing.
LOCK_DIR="${LOCK_DIR:-$REPO_ROOT/.chump-locks}"
CLUSTER_SENT_DIR="$LOCK_DIR/.cluster-sent"
mkdir -p "$CLUSTER_SENT_DIR" 2>/dev/null || true

# INFRA-1241: route ambient appends through helper (surfaces errors to stderr).
# shellcheck source=lib/ambient-write.sh
source "${SCRIPT_DIR}/lib/ambient-write.sh"

CLUSTER_THRESHOLD=3                   # 3+ PRs = cluster
CLUSTER_WINDOW_S="${CHUMP_PR_CLUSTER_WINDOW_S:-7200}"           # 2h window
RESEND_COOLDOWN_S="${CHUMP_PR_CLUSTER_RESEND_COOLDOWN_S:-86400}"  # 24h

# INFRA-2754: run-level observability. Every invocation — regardless of
# outcome — emits kind=pr_stuck_cluster_detector_run so the operator can see
# mutation cost (gap_reserve_calls) without grepping logs.
_pscd_ms_now() {
    python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || \
        echo $(( $(date +%s) * 1000 ))
}
_PSCD_RUN_T0_MS="$(_pscd_ms_now)"
_PSCD_GAP_RESERVE_CALLS=0

_pscd_emit_run_event() {
    local outcome="$1" stuck_pr_count="${2:-0}"
    local now_ms duration_ms ts
    now_ms="$(_pscd_ms_now)"
    duration_ms=$(( now_ms - _PSCD_RUN_T0_MS ))
    [ "$duration_ms" -lt 0 ] && duration_ms=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "$LOCK_DIR/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"pr_stuck_cluster_detector_run","outcome":"%s","stuck_pr_count":%d,"duration_ms":%d,"gap_reserve_calls":%d}' \
            "$ts" "$outcome" "$stuck_pr_count" "$duration_ms" "$_PSCD_GAP_RESERVE_CALLS")"
}
trap '_pscd_emit_run_event "${_PSCD_OUTCOME:-error}" "${_PSCD_STUCK_PR_COUNT:-0}"' EXIT

APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --window) CLUSTER_WINDOW_S="$2"; shift 2 ;;
        --threshold) CLUSTER_THRESHOLD="$2"; shift 2 ;;
        --cooldown) RESEND_COOLDOWN_S="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \?//'; _PSCD_OUTCOME="help"; exit 0 ;;
        *) echo "[pr-stuck-cluster-detector] unknown arg: $1" >&2; _PSCD_OUTCOME="bad_args"; exit 2 ;;
    esac
done

# Parse ambient.jsonl for pr_stuck events in the sliding window.
# Extract: timestamp, pr number, gap id.
parse_stuck_events() {
    local now_epoch=$1
    local window_s=$2
    local ambient_path=$3
    local cutoff_epoch=$(( now_epoch - window_s ))

    # jq: select kind==pr_stuck, convert ts to epoch, filter within window,
    # extract pr and gap fields, deduplicate by PR number.
    python3 << PYTHON_EOF
import sys, json, re
from datetime import datetime

now_epoch = $now_epoch
window_s = $window_s
cutoff_epoch = now_epoch - window_s

stuck_prs = {}  # pr_num -> (gap_id, ts_iso, age_s)

try:
    ambient_path = "$ambient_path"
    with open(ambient_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get('kind') != 'pr_stuck':
                    continue

                ts_iso = ev.get('ts', '')
                if not ts_iso:
                    continue

                # Parse ISO 8601 timestamp.
                try:
                    dt = datetime.fromisoformat(ts_iso.replace('Z', '+00:00'))
                    ts_epoch = int(dt.timestamp())
                except:
                    continue

                if ts_epoch < cutoff_epoch:
                    continue

                pr_num = ev.get('pr')
                if not pr_num:
                    continue

                gap_id = ev.get('gap', '')
                age_s = now_epoch - ts_epoch

                # Deduplicate: keep the *first* stuck event per PR in the window.
                if pr_num not in stuck_prs:
                    stuck_prs[pr_num] = (gap_id, ts_iso, age_s)
            except:
                continue

    # Output one line per stuck PR: pr_num|gap_id|ts_iso|age_s
    for pr_num in sorted(stuck_prs.keys()):
        gap_id, ts_iso, age_s = stuck_prs[pr_num]
        print(f"{pr_num}|{gap_id}|{ts_iso}|{age_s}")
except Exception as e:
    sys.stderr.write(f"[pr-stuck-cluster-detector] parse error: {e}\\n")
    sys.exit(1)
PYTHON_EOF
}

now_epoch="$(date +%s)"

# Pull stuck events from ambient.jsonl.
ambient_path="$LOCK_DIR/ambient.jsonl"
if [ ! -f "$ambient_path" ]; then
    echo "[pr-stuck-cluster-detector] no ambient.jsonl yet"
    _PSCD_OUTCOME="no_op" _PSCD_STUCK_PR_COUNT=0
    exit 0
fi

stuck_tmp="$(mktemp)"
trap 'rm -f "$stuck_tmp"; _pscd_emit_run_event "${_PSCD_OUTCOME:-error}" "${_PSCD_STUCK_PR_COUNT:-0}"' EXIT

parse_stuck_events "$now_epoch" "$CLUSTER_WINDOW_S" "$ambient_path" > "$stuck_tmp" 2>/dev/null
if [ ! -s "$stuck_tmp" ]; then
    echo "[pr-stuck-cluster-detector] no stuck events in window"
    _PSCD_OUTCOME="no_op" _PSCD_STUCK_PR_COUNT=0
    exit 0
fi

# Count distinct PRs in the window.
stuck_pr_count=$(wc -l < "$stuck_tmp")
_PSCD_STUCK_PR_COUNT="$stuck_pr_count"
if [ "$stuck_pr_count" -lt "$CLUSTER_THRESHOLD" ]; then
    echo "[pr-stuck-cluster-detector] $stuck_pr_count stuck PRs (threshold=$CLUSTER_THRESHOLD) — no cluster"
    _PSCD_OUTCOME="no_op"
    exit 0
fi

# Cluster detected. Build context.
echo "[pr-stuck-cluster-detector] CLUSTER DETECTED: $stuck_pr_count stuck PRs in $((CLUSTER_WINDOW_S/3600))h window"

# Collect PR numbers, gap ids, and build cluster id (sort-based hash).
pr_list=""
gap_list=""
while IFS='|' read -r pr_num gap_id ts_iso age_s; do
    [ -z "$pr_num" ] && continue
    pr_list="$pr_list $pr_num"
    gap_list="$gap_list $gap_id"
done < "$stuck_tmp"

# Cluster id = hash(sorted pr_nums) for dedup purposes.
cluster_id="$(echo "$pr_list" | tr ' ' '\n' | sort -n | tr '\n' ',' | sha256sum | cut -c1-8)"

# Dedup: skip if we filed a cluster for these PRs recently.
cluster_stamp="$CLUSTER_SENT_DIR/$cluster_id.ts"
if [ -f "$cluster_stamp" ]; then
    cluster_stamp_ts="$(cat "$cluster_stamp" 2>/dev/null || echo 0)"
    if [ "$cluster_stamp_ts" -gt 0 ] && [ $(( now_epoch - cluster_stamp_ts )) -lt "$RESEND_COOLDOWN_S" ]; then
        echo "[pr-stuck-cluster-detector] cluster $cluster_id filed within cooldown; skip"
        _PSCD_OUTCOME="no_op"
        exit 0
    fi
fi

# Build description with affected PRs, ages, gaps.
description="$(cat << DESC_EOF
Cluster detected: $stuck_pr_count PRs stuck >2h simultaneously.

Affected PRs: $(echo "$pr_list" | xargs)

Details:
$(cat "$stuck_tmp" | while IFS='|' read -r pr_num gap_id ts_iso age_s; do
  echo "  - PR #$pr_num ($gap_id): stuck for ~$((age_s/3600))h"
done)

Common root cause hypotheses:
- CI flake: one critical check failing repeatedly; re-run via comment
- Rate limit: GitHub API exhaustion blocking merges; monitor remaining_graphql
- Human forget: gaps filed but PRs armed with auto-merge; operator did not monitor queue
- Rebase conflict storm: multiple PRs conflict on merge; fleet needs rebase + push cycle

Suggested actions:
1. Check ambient.jsonl for graphql_exhausted or gh_self_throttled events
2. Run: chump gap list --status open | head -20 (is the queue stalled?)
3. For each stuck PR: gh pr checks <N> to identify common failing check
4. If one check is culprit: re-run via gh pr comment <N> -b "/rerun-failed"
5. If rebase needed: scripts/coord/pr-rescue.sh for automated recovery
6. Monitor bot-merge.sh logs to spot contention or manual blockers

Scale-down trigger (CLAUDE.md): if this gap files, consider:
  tmux kill-pane -t fleet-worker-3  # drop to 2 workers
  Log scale_change event to ambient.jsonl

Depends on: INFRA-1251 (pr-stuck announcer must run continuously)
DESC_EOF
)"

if [ "$APPLY" -eq 1 ]; then
    # File the gap.
    title="RESILIENT: PR cluster stuck — $stuck_pr_count PRs blocked >2h; diagnose root cause + recover"

    # Use chump gap reserve to file.
    _PSCD_GAP_RESERVE_CALLS=$(( _PSCD_GAP_RESERVE_CALLS + 1 ))
    result="$(chump gap reserve --domain INFRA --priority P0 --title "$title" --description "$description" 2>&1)"
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        # Extract gap id from output.
        gap_id="$(echo "$result" | grep -oE 'INFRA-[0-9]+' | head -1)"
        if [ -n "$gap_id" ]; then
            echo "[pr-stuck-cluster-detector] filed $gap_id for PR cluster: $(echo "$pr_list" | xargs)"

            # Emit cluster detection event.
            _ambient_write "$LOCK_DIR/ambient.jsonl" \
                "$(printf '{"ts":"%s","kind":"pr_stuck_cluster","cluster_id":"%s","pr_count":%d,"prs":%s,"gap":"%s","window_h":%d}' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    "$cluster_id" \
                    "$stuck_pr_count" \
                    "$(echo "$pr_list" | tr ' ' ',' | sed 's/^/[/;s/,$/]/')" \
                    "$gap_id" \
                    "$((CLUSTER_WINDOW_S/3600))")"

            # Record the cluster filing time.
            printf '%s' "$now_epoch" > "$cluster_stamp"
            _PSCD_OUTCOME="cluster_filed"
        else
            echo "[pr-stuck-cluster-detector] ERROR: gap reserve succeeded but no ID extracted"
            # Transient: reserve succeeded but the ID was unparseable from output.
            _PSCD_OUTCOME="gap_id_extract_failed"
            exit 1
        fi
    else
        echo "[pr-stuck-cluster-detector] ERROR: gap reserve failed"
        echo "$result" >&2
        # Permanent: chump gap reserve itself returned nonzero.
        _PSCD_OUTCOME="gap_reserve_failed"
        exit 1
    fi
else
    echo "[pr-stuck-cluster-detector] WOULD file gap for cluster $cluster_id:"
    echo "  Title: RESILIENT: PR cluster stuck — $stuck_pr_count PRs blocked >2h; diagnose root cause + recover"
    echo "  PRs: $(echo "$pr_list" | xargs)"
    echo "  Gaps: $(echo "$gap_list" | xargs)"
    _PSCD_OUTCOME="dry_run"
fi

exit 0
