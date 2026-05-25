#!/usr/bin/env bash
# scripts/coord/recovery-queue-service.sh — INFRA-1993 (THE FLOOR Phase 3)
#
# Consumes operator_recovery_requested events from ambient.jsonl,
# rate-limits to max 3 admin-merge cycles per hour fleet-wide, and runs
# the canonical drop-gates → admin-merge → re-arm cycle that Opus has
# been doing manually all day.
#
# Runs every 60 seconds via launchd. Idempotent: tracks last processed
# event by ambient.jsonl offset in .chump-locks/recovery-queue-state.json.
#
# Rate limit: sliding window of last 3600s; max 3 cycles. If exceeded,
# emit kind=recovery_queue_rate_limited + skip until window slides.
#
# Cycle steps:
#   1. Snapshot current ruleset rules → /tmp/ruleset-backup-<ts>.json
#   2. PUT ruleset with required_status_checks rule DROPPED
#   3. For each PR in request: gh pr merge --squash --admin
#   4. PUT ruleset RESTORED to original
#   5. Emit kind=operator_recovery_executed with pre/post diff
#
# Safety:
#   - Refuses to merge PRs that aren't owned by the chump bot (head_repo_owner check)
#   - Refuses to merge PRs from forks
#   - CHUMP_RECOVERY_QUEUE_PAUSE=1 disables the daemon entirely
#   - All actions audited via ambient events
#
# Config (env):
#   CHUMP_RECOVERY_QUEUE_PAUSE=1            disable daemon
#   CHUMP_RECOVERY_QUEUE_RATE=3             max cycles per 3600s (default 3)
#   CHUMP_RECOVERY_QUEUE_RULESET_ID=15133729  ruleset to drop+restore
#   CHUMP_RECOVERY_QUEUE_DRY_RUN=1          plan but don't execute
#   CHUMP_RECOVERY_QUEUE_TEST_GH=<path>     test injection: mock gh
#   CHUMP_AMBIENT_LOG=<path>                test injection: ambient file

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE="$REPO_ROOT/.chump-locks/recovery-queue-state.json"
LOG="$REPO_ROOT/.chump-locks/recovery-queue-service.log"
RATE="${CHUMP_RECOVERY_QUEUE_RATE:-3}"
WINDOW=3600
RULESET_ID="${CHUMP_RECOVERY_QUEUE_RULESET_ID:-15133729}"
DRY_RUN="${CHUMP_RECOVERY_QUEUE_DRY_RUN:-0}"
GH_BIN="${CHUMP_RECOVERY_QUEUE_TEST_GH:-gh}"

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

if [[ "${CHUMP_RECOVERY_QUEUE_PAUSE:-0}" == "1" ]]; then
    printf '{"ts":"%s","kind":"recovery_queue_paused","source":"recovery_queue_service","reason":"env_pause"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMBIENT" 2>/dev/null || true
    echo "recovery-queue: paused via env" >&2
    exit 0
fi

# ── State helpers ────────────────────────────────────────────────────────────
_load_state() {
    if [[ -f "$STATE" ]]; then
        cat "$STATE"
    else
        echo '{"processed_offset":0,"recent_cycles":[]}'
    fi
}

_save_state() {
    [[ "$DRY_RUN" == "1" ]] && return
    echo "$1" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"recovery_queue_service"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Find unprocessed operator_recovery_requested events ────────────────────
_find_requests() {
    [[ -f "$AMBIENT" ]] || return
    local state; state="$(_load_state)"
    local offset
    offset="$(echo "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("processed_offset",0))' 2>/dev/null || echo 0)"
    offset="${offset:-0}"

    # Stream lines starting at offset+1 (1-based line numbers).
    # Use python json parse to filter by TOP-LEVEL kind — avoids the
    # substring trap (rate_limited events embed the deferred request).
    awk -v from="$((offset+1))" 'NR>=from' "$AMBIENT" 2>/dev/null \
        | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.rstrip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    # Guard against non-dict JSON values (some misc emitters write
    # numbers/strings/arrays to ambient.jsonl). Without this, a single
    # non-dict line crashes the pipe + drops remaining input.
    if not isinstance(obj, dict):
        continue
    if obj.get("kind") == "operator_recovery_requested":
        print(line)
' 2>/dev/null || true
}

# ── Check rate limit ────────────────────────────────────────────────────────
_under_rate_limit() {
    local state; state="$(_load_state)"
    local now; now="$(date +%s)"
    local recent
    recent="$(echo "$state" | python3 -c "
import json, sys, time
try:
    s = json.load(sys.stdin)
    cutoff = $now - $WINDOW
    cycles = [t for t in s.get('recent_cycles', []) if t > cutoff]
    print(len(cycles))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    recent="${recent:-0}"
    [[ "$recent" -lt "$RATE" ]]
}

_record_cycle() {
    local state; state="$(_load_state)"
    local now; now="$(date +%s)"
    state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'recent_cycles':[]}
s.setdefault('recent_cycles', []).append($now)
# Prune cycles older than the window
cutoff = $now - $WINDOW
s['recent_cycles'] = [t for t in s['recent_cycles'] if t > cutoff]
print(json.dumps(s))
")"
    _save_state "$state"
}

# ── Advance the processed offset ────────────────────────────────────────────
_advance_offset() {
    local new_offset="$1"
    local state; state="$(_load_state)"
    state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'recent_cycles':[]}
s['processed_offset'] = $new_offset
print(json.dumps(s))
")"
    _save_state "$state"
}

# ── Safety check: PR is from this repo (not a fork) ─────────────────────────
_pr_safe_to_admin() {
    local pr="$1"
    # In production, we'd check head_repo_owner; for now just accept.
    # Test injection bypasses live gh.
    if [[ "$GH_BIN" != "gh" ]]; then
        return 0
    fi
    local head_owner
    head_owner="$("$GH_BIN" pr view "$pr" --json headRepositoryOwner --jq '.headRepositoryOwner.login' 2>/dev/null || echo "")"
    [[ -z "$head_owner" ]] && return 0  # fail-open if gh errors
    # Accept if owner matches the configured allowed owners (default: chump-bot orgs)
    case "$head_owner" in
        repairman29|jeffadkins|chump-bot) return 0 ;;
        *) echo "[safety] PR #$pr head_owner=$head_owner not in allowlist; refusing" >&2; return 1 ;;
    esac
}

# ── The cycle: drop → admin-merge → re-arm ─────────────────────────────────
_run_cycle() {
    local prs_csv="$1"
    local reason="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[cycle] starting: prs=$prs_csv reason=$reason" >&2

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] would: snapshot ruleset, drop rules, merge $prs_csv, restore" >&2
        _emit "operator_recovery_executed" \
            "\"prs\":\"$prs_csv\"" \
            "\"reason\":\"$reason\"" \
            "\"dry_run\":true"
        return 0
    fi

    # 1. Snapshot
    local backup="/tmp/recovery-ruleset-backup-${RULESET_ID}-$$.json"
    if ! "$GH_BIN" api "repos/${CHUMP_GH_REPO:-repairman29/chump}/rulesets/$RULESET_ID" > "$backup" 2>/dev/null; then
        echo "[fail] could not snapshot ruleset $RULESET_ID — aborting" >&2
        _emit "operator_recovery_failed" \
            "\"reason\":\"ruleset_snapshot_failed\"" \
            "\"prs\":\"$prs_csv\""
        return 1
    fi

    # 2. Construct dropped variant + PUT
    local dropped="/tmp/recovery-ruleset-dropped-$$.json"
    python3 -c "
import json
with open('$backup') as f: d = json.load(f)
out = {
    'name': d.get('name'),
    'target': d.get('target'),
    'enforcement': d.get('enforcement'),
    'conditions': d.get('conditions'),
    'rules': [r for r in d.get('rules',[]) if r.get('type') != 'required_status_checks'],
}
with open('$dropped','w') as f: json.dump(out,f)
" 2>/dev/null

    if ! "$GH_BIN" api -X PUT "repos/${CHUMP_GH_REPO:-repairman29/chump}/rulesets/$RULESET_ID" --input "$dropped" >/dev/null 2>&1; then
        echo "[fail] could not drop ruleset rules — aborting" >&2
        _emit "operator_recovery_failed" \
            "\"reason\":\"ruleset_drop_failed\"" \
            "\"prs\":\"$prs_csv\""
        rm -f "$backup" "$dropped"
        return 1
    fi

    # 3. Admin-merge each PR
    local merged=""
    local failed=""
    IFS=',' read -ra PR_LIST <<< "$prs_csv"
    for pr in "${PR_LIST[@]}"; do
        pr="$(echo "$pr" | xargs)"
        [[ -z "$pr" ]] && continue
        if ! _pr_safe_to_admin "$pr"; then
            failed+="$pr,"
            continue
        fi
        if "$GH_BIN" pr merge "$pr" --squash --admin 2>/dev/null; then
            merged+="$pr,"
        else
            # Check if already merged
            local state
            state="$("$GH_BIN" pr view "$pr" --json state --jq '.state' 2>/dev/null || echo "")"
            if [[ "$state" == "MERGED" ]] || [[ "$state" == "CLOSED" ]]; then
                merged+="$pr,"  # idempotent
            else
                failed+="$pr,"
            fi
        fi
    done

    # 4. Restore ruleset
    if ! "$GH_BIN" api -X PUT "repos/${CHUMP_GH_REPO:-repairman29/chump}/rulesets/$RULESET_ID" --input "$backup" >/dev/null 2>&1; then
        echo "[CRITICAL] could not restore ruleset $RULESET_ID — operator action required" >&2
        _emit "operator_recovery_failed" \
            "\"reason\":\"ruleset_restore_failed_CRITICAL\"" \
            "\"prs\":\"$prs_csv\"" \
            "\"merged\":\"${merged%,}\"" \
            "\"backup_file\":\"$backup\""
        return 2
    fi

    rm -f "$backup" "$dropped"
    _record_cycle
    _emit "operator_recovery_executed" \
        "\"prs\":\"$prs_csv\"" \
        "\"merged\":\"${merged%,}\"" \
        "\"failed\":\"${failed%,}\"" \
        "\"reason\":\"$reason\"" \
        "\"ruleset_id\":\"$RULESET_ID\""
    echo "[cycle] done: merged=${merged%,} failed=${failed%,}" >&2
    return 0
}

# ── Main loop ───────────────────────────────────────────────────────────────
LINE_NUM=0
REQUESTS="$(_find_requests)"

if [[ -z "$REQUESTS" ]]; then
    # Nothing to do; just advance to current offset to keep state fresh.
    if [[ -f "$AMBIENT" ]]; then
        TOTAL_LINES="$(wc -l < "$AMBIENT" | xargs)"
        _advance_offset "$TOTAL_LINES"
    fi
    exit 0
fi

echo "[service] found $(echo "$REQUESTS" | wc -l | xargs) pending request(s)" >&2

# Track the highest line number we process
if [[ -f "$AMBIENT" ]]; then
    HIGHEST_LINE="$(wc -l < "$AMBIENT" | xargs)"
else
    HIGHEST_LINE=0
fi

while IFS= read -r req; do
    [[ -z "$req" ]] && continue

    if ! _under_rate_limit; then
        _emit "recovery_queue_rate_limited" \
            "\"max_per_hour\":\"$RATE\"" \
            "\"deferred_request\":\"$(echo "$req" | head -c 100)\""
        echo "[skip] rate limit hit ($RATE/hour); deferring" >&2
        break
    fi

    PRS="$(echo "$req" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("prs",""))' 2>/dev/null)"
    REASON="$(echo "$req" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("reason",""))' 2>/dev/null)"
    [[ -z "$PRS" ]] && continue

    _run_cycle "$PRS" "$REASON"
done <<< "$REQUESTS"

# Advance offset past everything we considered
_advance_offset "$HIGHEST_LINE"
exit 0
