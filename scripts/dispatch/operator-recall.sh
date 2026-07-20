#!/usr/bin/env bash
# operator-recall.sh — INFRA-626: detect halt-class conditions and page the operator.
#
# Checks four conditions by scanning ambient.jsonl, then:
#   1. Emits kind=operator_recall to ambient.jsonl (idempotent — cooldown-gated)
#   2. POSTs a JSON body to CHUMP_OPERATOR_RECALL_URL if set
#
# Conditions:
#   (a) AUTH_DEAD           — ≥ CHUMP_AUTH_STORM_RECALL_THRESHOLD fleet_auth_storm
#                             events with action=worker_exit in the last
#                             CHUMP_AUTH_STORM_WINDOW_SECS (default 5, 3600)
#   (b) COST_CAP            — cost_cap_exceeded event in ambient.jsonl within 2 h,
#                             OR `chump cost-watch --hard-cap` exits non-zero
#   (c) CI_BROKEN           — ≥ CHUMP_CI_BROKEN_THRESHOLD pr_stuck events with
#                             reason containing "ci" in CHUMP_CI_BROKEN_WINDOW_SECS
#                             (default 3, 7200)
#   (d) QUEUE_STARVE        — fleet_queue_depth event with pickable_count=0 AND no
#                             gap_reserved event in CHUMP_QUEUE_STARVE_SECS (default 86400)
#   (e) RUNNER_GHOST_ONLINE — queued workflow_runs older than
#                             CHUMP_RUNNER_QUEUE_THRESHOLD_S (default 300) exist AND
#                             ≥1 self-hosted runner has status=online,busy=false.
#                             Guard: CHUMP_RUNNER_GHOST_ONLINE_DETECT (default 1, set to 0 to disable)
#   (f) DISK_CRITICAL       — ≥1 disk_critical event in last
#                             CHUMP_DISK_CRITICAL_WINDOW_SECS (default 600) AND
#                             current free% < CHUMP_DISK_CRITICAL_PCT (default 5).
#                             Fires when the INFRA-2304 reactor's escalated reap
#                             could not recover sufficient headroom — operator
#                             must intervene (manual reap, fleet pause, etc.)
#
# Usage:
#   operator-recall.sh                  # auto-detect all conditions; exit 0
#   operator-recall.sh --check-only     # exit 1 if any halt condition is active
#   operator-recall.sh --condition NAME --reason "..." # emit + notify directly
#
# Env:
#   CHUMP_OPERATOR_RECALL_URL              webhook endpoint (curl POST JSON)
#   CHUMP_OPERATOR_RECALL_COOLDOWN_SECS    suppress duplicate recalls (default 3600)
#   CHUMP_AUTH_STORM_RECALL_THRESHOLD      default 5
#   CHUMP_AUTH_STORM_WINDOW_SECS           default 3600
#   CHUMP_CI_BROKEN_THRESHOLD              default 3
#   CHUMP_CI_BROKEN_WINDOW_SECS            default 7200
#   CHUMP_QUEUE_STARVE_SECS                default 86400
#   CHUMP_RUNNER_QUEUE_THRESHOLD_S         seconds a run stays queued before ghost-online fires (default 300)
#   CHUMP_RUNNER_GHOST_ONLINE_DETECT       set to 0 to disable RUNNER_GHOST_ONLINE detection (default 1)
#   CHUMP_DISK_CRITICAL_WINDOW_SECS        recency window for disk_critical events (default 600)
#   CHUMP_DISK_CRITICAL_PCT                free% threshold below which to page (default 5)
#   CHUMP_AMBIENT_LOG                      path to ambient.jsonl

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_lock_dir="$(dirname "$_amb")"

_recall_url="${CHUMP_OPERATOR_RECALL_URL:-}"
_cooldown="${CHUMP_OPERATOR_RECALL_COOLDOWN_SECS:-3600}"
_auth_threshold="${CHUMP_AUTH_STORM_RECALL_THRESHOLD:-5}"
_auth_window="${CHUMP_AUTH_STORM_WINDOW_SECS:-3600}"
_ci_threshold="${CHUMP_CI_BROKEN_THRESHOLD:-3}"
_ci_window="${CHUMP_CI_BROKEN_WINDOW_SECS:-7200}"
_queue_starve="${CHUMP_QUEUE_STARVE_SECS:-86400}"
_runner_queue_threshold="${CHUMP_RUNNER_QUEUE_THRESHOLD_S:-300}"
_runner_ghost_detect="${CHUMP_RUNNER_GHOST_ONLINE_DETECT:-1}"
_disk_critical_window="${CHUMP_DISK_CRITICAL_WINDOW_SECS:-600}"
_disk_critical_pct="${CHUMP_DISK_CRITICAL_PCT:-5}"

_check_only=0
_forced_condition=""
_forced_reason=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) _check_only=1; shift ;;
        --condition)  _forced_condition="$2"; shift 2 ;;
        --reason)     _forced_reason="$2"; shift 2 ;;
        *) echo "Usage: $0 [--check-only] [--condition NAME --reason TEXT]" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

_now_epoch() { date +%s; }

_emit_recall() {
    # Args: condition reason [class] [remediation]
    # class/remediation (META-101) — QUEUE_SATURATED subclass detail. Optional;
    # omitted for conditions (a)-(d),(f) that don't have a subclass.
    local condition="$1" reason="$2" class="${3:-}" remediation="${4:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    mkdir -p "$_lock_dir" 2>/dev/null || true

    # Cooldown: skip if we already emitted this condition(+class) recently.
    # Keyed on class too so RUNNERS_GHOSTED and QUEUE_SATURATED_GH_HOSTED don't
    # suppress each other when both fire in the same run.
    local cooldown_key="${condition}${class:+-$class}"
    local cooldown_file="$_lock_dir/operator-recall-${cooldown_key}.ts"
    if [[ -f "$cooldown_file" ]]; then
        local last_ts; last_ts="$(cat "$cooldown_file" 2>/dev/null || echo 0)"
        local age=$(( $(_now_epoch) - last_ts ))
        if (( age < _cooldown )); then
            return 0
        fi
    fi

    # Emit to ambient.jsonl.
    local body
    if [[ -n "$class" ]]; then
        body="$(printf '{"ts":"%s","kind":"operator_recall","condition":"%s","class":"%s","reason":"%s","remediation":"%s"}' \
            "$ts" "$condition" "$class" "$reason" "$remediation")"
    else
        body="$(printf '{"ts":"%s","kind":"operator_recall","condition":"%s","reason":"%s"}' \
            "$ts" "$condition" "$reason")"
    fi
    printf '%s\n' "$body" >> "$_amb" 2>/dev/null || true

    # Update cooldown timestamp.
    _now_epoch > "$cooldown_file" 2>/dev/null || true

    echo "[operator-recall] RECALL condition=${condition}${class:+ class=$class} reason=${reason}"

    # Webhook notification.
    if [[ -n "$_recall_url" ]]; then
        local payload
        payload="$(printf '{"ts":"%s","condition":"%s","reason":"%s","fleet":"%s"}' \
            "$ts" "$condition" "$reason" "${FLEET_SESSION:-chump-fleet}")"
        curl -sf -X POST -H "Content-Type: application/json" \
            -d "$payload" "$_recall_url" >/dev/null 2>&1 || \
            echo "[operator-recall] WARNING: webhook POST failed (url=${_recall_url})" >&2
    fi
}

# ── (e) RUNNER_GHOST_ONLINE detection ─────────────────────────────────────────

_detect_runner_ghost_online() {
    local cache_db="$REPO_ROOT/.chump/github_cache.db"
    local now_epoch; now_epoch="$(_now_epoch)"
    local stale_threshold="$_runner_queue_threshold"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --- Step 1: find queued workflow_runs older than threshold (+ run_ids, META-101) ---
    local queued_count=0
    local oldest_age_s=0
    local queued_run_ids=""

    if [[ -f "$cache_db" ]]; then
        # Read from cache: workflow_run_cache table (INFRA-1872 shape)
        local cache_result
        cache_result=$(python3 - "$cache_db" "$now_epoch" "$stale_threshold" <<'PYEOF' 2>/dev/null
import sys, sqlite3
from datetime import datetime, timezone

db_path, now_epoch, threshold = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    tables = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
    count = 0
    oldest_age = 0
    ids = []
    if "workflow_run_cache" in tables:
        rows = cur.execute(
            "SELECT run_id, created_at FROM workflow_run_cache WHERE status='queued'"
        ).fetchall()
        for (run_id, created_at) in rows:
            try:
                created_epoch = int(datetime.fromisoformat(
                    created_at.rstrip("Z")).replace(tzinfo=timezone.utc).timestamp())
            except Exception:
                continue
            age = now_epoch - created_epoch
            if age >= threshold:
                count += 1
                ids.append(str(run_id))
                if age > oldest_age:
                    oldest_age = age
    # META-101 AC2 step2: sample up to 5 queued run_ids for job-level classification
    print(f"{count} {oldest_age} {','.join(ids[:5])}")
    conn.close()
except Exception:
    print("0 0 ")
PYEOF
        )
        queued_count=$(echo "$cache_result" | awk '{print $1}')
        oldest_age_s=$(echo "$cache_result" | awk '{print $2}')
        queued_run_ids=$(echo "$cache_result" | awk '{print $3}')
    fi

    # No stale queued runs — nothing to do.
    if [[ -z "$queued_count" ]] || (( queued_count == 0 )); then
        return 0
    fi

    # --- Step 2: check for online-but-idle self-hosted runners via GitHub API ---
    local idle_runners=0
    local idle_runner_labels_json="[]"
    local runners_json
    local _gh_repo="${GITHUB_REPOSITORY:-repairman29/chump}"
    runners_json=$(gh api "repos/${_gh_repo}/actions/runners" --paginate 2>/dev/null || echo "")

    if [[ -n "$runners_json" ]]; then
        local _idle_result
        _idle_result=$(python3 - "$runners_json" <<'PYEOF' 2>/dev/null
import sys, json
try:
    data = json.loads(sys.argv[1])
    runners = data if isinstance(data, list) else data.get("runners", [])
    idle = [
        r for r in runners
        if r.get("status") == "online" and not r.get("busy", True)
        and any(l.get("name") == "self-hosted" for l in r.get("labels", []))
    ]
    labels = [[l.get("name") for l in r.get("labels", [])] for r in idle]
    print(len(idle))
    print(json.dumps(labels))
except Exception:
    print(0)
    print("[]")
PYEOF
        )
        idle_runners=$(echo "$_idle_result" | sed -n '1p')
        idle_runner_labels_json=$(echo "$_idle_result" | sed -n '2p')
    fi

    idle_runners="${idle_runners//[[:space:]]/}"
    if [[ -z "$idle_runners" ]]; then
        idle_runners=0
    fi
    if [[ -z "$idle_runner_labels_json" ]]; then
        idle_runner_labels_json="[]"
    fi

    # --- Step 2b (META-101 AC2 step2): fetch + classify jobs for sampled queued runs ---
    # Classifies each queued run's requested runs-on labels as self-hosted (matches an
    # idle runner's label set) or GitHub-hosted (ubuntu-*/macos-*/windows-* labels).
    local jobs_blob="[]"
    if [[ -n "$queued_run_ids" ]]; then
        jobs_blob="["
        local _first=1
        local run_id
        IFS=',' read -ra _run_id_arr <<< "$queued_run_ids"
        for run_id in "${_run_id_arr[@]}"; do
            [[ -z "$run_id" ]] && continue
            local _jobs_json
            _jobs_json=$(gh api "repos/${_gh_repo}/actions/runs/${run_id}/jobs" 2>/dev/null || echo '{"jobs":[]}')
            if (( _first )); then
                _first=0
            else
                jobs_blob+=","
            fi
            jobs_blob+="{\"run_id\":${run_id},\"jobs\":$(python3 -c "
import json,sys
try:
    d = json.loads(sys.argv[1])
    print(json.dumps(d.get('jobs', [])))
except Exception:
    print('[]')
" "$_jobs_json" 2>/dev/null || echo '[]')}"
        done
        jobs_blob+="]"
    fi

    # --- Step 3 (META-101): classify + decide subclass — RUNNERS_GHOSTED vs QUEUE_SATURATED_GH_HOSTED ---
    local _classify_result
    _classify_result=$(python3 - "$jobs_blob" "$idle_runner_labels_json" <<'PYEOF' 2>/dev/null
import sys, json, re

jobs_blob, idle_labels_json = sys.argv[1], sys.argv[2]
GH_HOSTED_RX = re.compile(r'^(ubuntu|macos|windows)(-|$)', re.IGNORECASE)

try:
    runs = json.loads(jobs_blob)
except Exception:
    runs = []
try:
    idle_label_sets = [set(l for l in labels if l) for labels in json.loads(idle_labels_json)]
except Exception:
    idle_label_sets = []

self_hosted_run_ids = []
gh_hosted_run_ids = []
gh_hosted_labels = set()

for run in runs:
    run_id = run.get("run_id")
    for job in run.get("jobs", []):
        labels = job.get("labels", []) or []
        label_set = set(labels)
        if "self-hosted" in label_set:
            # Self-hosted job — RUNNERS_GHOSTED candidate if it matches an idle runner's labels.
            if any(label_set.issubset(idle_set) or label_set & idle_set for idle_set in idle_label_sets) or not idle_label_sets:
                if run_id not in self_hosted_run_ids:
                    self_hosted_run_ids.append(run_id)
        elif any(GH_HOSTED_RX.match(l) for l in labels):
            if run_id not in gh_hosted_run_ids:
                gh_hosted_run_ids.append(run_id)
            gh_hosted_labels.update(l for l in labels if GH_HOSTED_RX.match(l))

print(json.dumps({
    "self_hosted_run_ids": self_hosted_run_ids,
    "gh_hosted_run_ids": gh_hosted_run_ids,
    "gh_hosted_labels": sorted(gh_hosted_labels),
}))
PYEOF
    )
    if [[ -z "$_classify_result" ]]; then
        _classify_result='{"self_hosted_run_ids":[],"gh_hosted_run_ids":[],"gh_hosted_labels":[]}'
    fi

    local _gh_hosted_run_ids _gh_hosted_labels _self_hosted_run_ids
    _gh_hosted_run_ids=$(echo "$_classify_result" | python3 -c "import json,sys; print(','.join(str(x) for x in json.load(sys.stdin).get('gh_hosted_run_ids',[])))" 2>/dev/null || echo "")
    _gh_hosted_labels=$(echo "$_classify_result" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin).get('gh_hosted_labels',[])))" 2>/dev/null || echo "")
    _self_hosted_run_ids=$(echo "$_classify_result" | python3 -c "import json,sys; print(','.join(str(x) for x in json.load(sys.stdin).get('self_hosted_run_ids',[])))" 2>/dev/null || echo "")

    # Informational pre-recall event (not cooldown-gated) — preserved for compat with existing consumers.
    if (( idle_runners >= 1 )); then
        local detect_body
        detect_body="$(printf '{"ts":"%s","kind":"runner_ghost_online_detected","queued_count":%d,"oldest_age_s":%d,"idle_runners":%d,"threshold_s":%d}' \
            "$ts" "$queued_count" "$oldest_age_s" "$idle_runners" "$stale_threshold")"
        printf '%s\n' "$detect_body" >> "$_amb" 2>/dev/null || true
    fi

    # AC4: QUEUE_SATURATED_GH_HOSTED — queued jobs target GitHub-hosted labels regardless
    # of self-hosted idle state; this is the actual root cause class (2026-05-24 wizard finding).
    if [[ -n "$_gh_hosted_run_ids" ]]; then
        local _reason="workflow run(s) [${_gh_hosted_run_ids}] queued for >${stale_threshold}s (oldest=${oldest_age_s}s) targeting GitHub-hosted runs-on label(s) [${_gh_hosted_labels}]; GH-hosted runner concurrency quota likely exhausted, not a self-hosted runner problem"
        local _remediation="no-restart-fix; reduce concurrent workflow triggers OR increase GH-hosted runner quota OR migrate affected workflows to self-hosted"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=RUNNER_GHOST_ONLINE class=QUEUE_SATURATED_GH_HOSTED: $_reason"
            _any_halt=1
        else
            _emit_recall "RUNNER_GHOST_ONLINE" "$_reason" "QUEUE_SATURATED_GH_HOSTED" "$_remediation"
        fi
    fi

    # AC3: RUNNERS_GHOSTED — self-hosted runner(s) online+idle AND queued jobs target
    # their labels but aren't being picked up.
    if [[ -n "$_self_hosted_run_ids" ]] && (( idle_runners >= 1 )); then
        local _reason="workflow run(s) [${_self_hosted_run_ids}] queued for >${stale_threshold}s (oldest=${oldest_age_s}s) targeting self-hosted labels, with ${idle_runners} self-hosted runner(s) online-but-idle; runner process likely wedged/ghost-online"
        local _remediation="launchctl restart suggested for the affected self-hosted runner service"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=RUNNER_GHOST_ONLINE class=RUNNERS_GHOSTED: $_reason"
            _any_halt=1
        else
            _emit_recall "RUNNER_GHOST_ONLINE" "$_reason" "RUNNERS_GHOSTED" "$_remediation"
        fi
    elif [[ -z "$_gh_hosted_run_ids" ]] && (( idle_runners >= 1 )); then
        # Fallback: job-label data unavailable (e.g. API mock without /jobs support) but
        # the original stale-queue + idle-runner contradiction still holds — preserve
        # META-100 behavior so existing consumers/tests keep working.
        local _reason="${queued_count} workflow run(s) queued for >${stale_threshold}s (oldest=${oldest_age_s}s) with ${idle_runners} self-hosted runner(s) online-but-idle; runners may be ghost-online"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=RUNNER_GHOST_ONLINE: $_reason"
            _any_halt=1
        else
            _emit_recall "RUNNER_GHOST_ONLINE" "$_reason"
        fi
    fi
}

# ── Forced mode (called by scripts or tests) ──────────────────────────────────

if [[ -n "$_forced_condition" ]]; then
    _emit_recall "$_forced_condition" "${_forced_reason:-manual trigger}"
    exit 0
fi

# ── Condition detection ───────────────────────────────────────────────────────

_any_halt=0

_scan_ambient() {
    # Returns lines from ambient.jsonl within the last N seconds matching a pattern.
    local window_secs="$1"
    local pattern="$2"
    local since=$(( $(_now_epoch) - window_secs ))

    if [[ ! -f "$_amb" ]]; then return; fi

    python3 - "$_amb" "$since" "$pattern" <<'PYEOF'
import sys, json, re
path, since, pattern = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rx = re.compile(pattern)
from datetime import datetime, timezone

def epoch_from_ts(ts):
    try:
        ts = ts.rstrip("Z")
        return int(datetime.fromisoformat(ts).replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        return 0

with open(path, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        ts = obj.get("ts", "")
        if epoch_from_ts(ts) < since:
            continue
        if rx.search(line):
            print(line)
PYEOF
}

# (a) AUTH_DEAD — fleet_auth_storm with action=worker_exit
_auth_exits=$(_scan_ambient "$_auth_window" '"kind":"fleet_auth_storm"' \
    | grep -c '"action":"worker_exit"' 2>/dev/null || echo 0)
_auth_exits="${_auth_exits//[[:space:]]/}"
if (( _auth_exits >= _auth_threshold )); then
    _reason="fleet_auth_storm with action=worker_exit seen ${_auth_exits}x in last ${_auth_window}s (threshold=${_auth_threshold}); auth credentials appear fully dead"
    if (( _check_only )); then
        echo "[operator-recall] HALT condition=AUTH_DEAD: $_reason"
        _any_halt=1
    else
        _emit_recall "AUTH_DEAD" "$_reason"
    fi
fi

# (b) COST_CAP — cost_cap_exceeded event in ambient within 2 h, or cost-watch hard-cap
_cost_hits=$(_scan_ambient "7200" '"kind":"cost_cap_exceeded"' | wc -l 2>/dev/null || echo 0)
_cost_hits="${_cost_hits//[[:space:]]/}"
_cost_over=0
if (( _cost_hits > 0 )); then
    _cost_over=1
else
    # Secondary: ask chump binary (best-effort, may not be available)
    if command -v chump >/dev/null 2>&1; then
        if ! chump cost-watch --hard-cap >/dev/null 2>&1; then
            _cost_over=1
        fi
    fi
fi
if (( _cost_over )); then
    _reason="daily cost cap exceeded (${_cost_hits} cost_cap_exceeded event(s) in ambient.jsonl or chump cost-watch --hard-cap triggered)"
    if (( _check_only )); then
        echo "[operator-recall] HALT condition=COST_CAP: $_reason"
        _any_halt=1
    else
        _emit_recall "COST_CAP" "$_reason"
    fi
fi

# (c) CI_BROKEN — pr_stuck with ci-related reason
_ci_raw=$(_scan_ambient "$_ci_window" '"kind":"pr_stuck"')
_ci_hits=$(echo "$_ci_raw" | grep -ic '"reason".*ci\|ci.*fail\|check.*fail\|all.*check' 2>/dev/null || echo 0)
_ci_hits="${_ci_hits//[[:space:]]/}"
# Fall back: count any pr_stuck if no reason field — conservative
if (( _ci_hits == 0 )); then
    _total_stuck=$(echo "$_ci_raw" | grep -c '"kind":"pr_stuck"' 2>/dev/null || echo 0)
    _total_stuck="${_total_stuck//[[:space:]]/}"
    if (( _total_stuck >= _ci_threshold * 2 )); then
        _ci_hits=$_ci_threshold
    fi
fi
if (( _ci_hits >= _ci_threshold )); then
    _reason="${_ci_hits} pr_stuck-with-CI-failure event(s) in last ${_ci_window}s (threshold=${_ci_threshold}); CI may be fully broken"
    if (( _check_only )); then
        echo "[operator-recall] HALT condition=CI_BROKEN: $_reason"
        _any_halt=1
    else
        _emit_recall "CI_BROKEN" "$_reason"
    fi
fi

# (d) QUEUE_STARVE — pickable_count=0 AND no gap_reserved in last N seconds
_recent_queue=$(_scan_ambient "300" '"kind":"fleet_queue_depth"' | tail -1)
_pickable=1  # default: assume queue has work
if [[ -n "$_recent_queue" ]]; then
    _pickable=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(int(d.get('pickable_count', 1)))
except Exception:
    print(1)
" "$_recent_queue" 2>/dev/null || echo 1)
fi
_pickable="${_pickable//[[:space:]]/}"

if (( _pickable == 0 )); then
    _recent_reserve=$(_scan_ambient "$_queue_starve" '"kind":"gap_reserved"' | wc -l 2>/dev/null || echo 0)
    _recent_reserve="${_recent_reserve//[[:space:]]/}"
    if (( _recent_reserve == 0 )); then
        _starve_hours=$(( _queue_starve / 3600 ))
        _reason="queue has 0 pickable gaps AND no gap_reserved event in last ${_starve_hours}h; fleet is starved with no new work arriving"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=QUEUE_STARVE: $_reason"
            _any_halt=1
        else
            _emit_recall "QUEUE_STARVE" "$_reason"
        fi
    fi
fi

# (e) RUNNER_GHOST_ONLINE — queued runs stale + runner online-but-idle contradiction
if (( _runner_ghost_detect != 0 )); then
    _detect_runner_ghost_online
fi

# (f) DISK_CRITICAL — disk_critical event recently AND current free% still below threshold
_disk_hits=$(_scan_ambient "$_disk_critical_window" '"kind":"disk_critical"' | wc -l 2>/dev/null || echo 0)
_disk_hits="${_disk_hits//[[:space:]]/}"
if (( _disk_hits > 0 )); then
    _cur_free_pct=$(df -P /System/Volumes/Data 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print 100-$5}' || echo 100)
    _cur_free_pct="${_cur_free_pct//[[:space:]]/}"
    if [[ -n "$_cur_free_pct" ]] && (( _cur_free_pct < _disk_critical_pct )); then
        _reason="${_disk_hits} disk_critical event(s) in last ${_disk_critical_window}s AND current free=${_cur_free_pct}% (<${_disk_critical_pct}%); reactor escalation insufficient — operator must intervene"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=DISK_CRITICAL: $_reason"
            _any_halt=1
        else
            _emit_recall "DISK_CRITICAL" "$_reason"
        fi
    fi
fi

if (( _check_only && _any_halt )); then
    exit 1
fi
exit 0
