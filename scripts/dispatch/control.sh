#!/usr/bin/env bash
# control.sh — INFRA-203: live status pane for the fleet.
#
# Spawned by run-fleet.sh as pane 0. Cheap, read-only loop showing:
#   • ambient.jsonl tail (last 10 events)
#   • PR queue depth (`gh pr list` count)
#   • per-agent current gap (parsed from .chump-locks/*.json)
#
# Refreshes every REFRESH_S seconds (default 5). Ctrl-C exits the pane only.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FLEET_SESSION="${FLEET_SESSION:-chump-fleet}"
FLEET_SIZE="${FLEET_SIZE:-?}"
REFRESH_S="${REFRESH_S:-5}"
FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1}"
FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"

cd "$REPO_ROOT"

trap 'echo; echo "[control] bye."; exit 0' INT TERM

# INFRA-558: emit fleet_queue_depth every 60s
_last_queue_emit=0

# INFRA-565: periodic fleet lease reaper (every 30 min)
_last_reap=0

while :; do
    clear
    printf '\033[1mchump fleet — session=%s  size=%s  refresh=%ss\033[0m\n' \
        "$FLEET_SESSION" "$FLEET_SIZE" "$REFRESH_S"
    printf '%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo

    # PR queue depth
    echo "── PRs (open, head=chump/*) ─────────────────────────────────"
    if command -v gh >/dev/null 2>&1; then
        gh pr list --state open --search 'head:chump/' \
            --json number,title,headRefName,statusCheckRollup \
            --template '{{range .}}#{{.number}}  {{.headRefName}}  {{.title}}{{"\n"}}{{end}}' \
            2>/dev/null | head -10 || echo "  (gh pr list failed)"
    else
        echo "  (gh CLI not on PATH)"
    fi
    echo

    # Active leases
    echo "── Active leases (.chump-locks/*.json) ──────────────────────"
    leases=$(ls "$REPO_ROOT/.chump-locks/"*.json 2>/dev/null || true)
    if [ -z "$leases" ]; then
        echo "  (none)"
    else
        for f in $leases; do
            python3 -c "
import json,sys,os
try: d=json.load(open('$f'))
except Exception: sys.exit(0)
gid = d.get('gap_id') or (d.get('pending_new_gap') or {}).get('id') or '?'
sid = d.get('session_id','?')
exp = d.get('expires_at','?')
print(f'  {gid:18s}  session={sid[:30]:30s}  expires={exp}')
" 2>/dev/null
        done
    fi
    echo

    # Ambient tail
    echo "── Ambient stream (last 10) ─────────────────────────────────"
    if [ -f "$REPO_ROOT/.chump-locks/ambient.jsonl" ]; then
        tail -10 "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null \
            | python3 -c "
import json,sys
for line in sys.stdin:
    try: e=json.loads(line)
    except Exception: continue
    ts = (e.get('ts') or '')[:19]
    kind = e.get('kind','?')
    sid = (e.get('session_id') or '')[:24]
    extra = ''
    for k in ('gap','path','sha','msg'):
        if e.get(k):
            extra = f' {k}={e[k]}'
            break
    print(f'  {ts}  {kind:14s}  {sid:24s}{extra}')
" 2>/dev/null
    else
        echo "  (no ambient stream yet)"
    fi
    echo

    # INFRA-558: emit fleet_queue_depth every 60s
    if (( SECONDS - _last_queue_emit >= 60 )); then
        _queue_json="$(chump gap list --status open --json 2>/dev/null || echo '[]')"
        if [[ -n "$_queue_json" && "$_queue_json" != "[]" ]]; then
            read -r _pickable _p0_count _oldest_p0_age < <(python3 - <<PYEOF
import json, os, sys
from datetime import date, datetime

gaps = json.loads("""$_queue_json""")
today = date.today()

prio_filter = [p.strip().upper() for p in os.environ.get("FLEET_PRIORITY_FILTER", "P0,P1").split(",") if p.strip()]
effort_filter = [e.strip().lower() for e in os.environ.get("FLEET_EFFORT_FILTER", "xs,s,m").split(",") if e.strip()]
domain_filter = [d.strip().lower() for d in os.environ.get("FLEET_DOMAIN_FILTER", "").split(",") if d.strip()]

pickable = 0
p0_count = 0
oldest_p0_opened = None

for g in gaps:
    p = (g.get("priority") or "").upper()
    e = (g.get("effort") or "").lower()
    d = (g.get("domain") or "").lower()

    if p == "P0":
        p0_count += 1
        od = g.get("opened_date") or g.get("created_at") or ""
        if od:
            try:
                opened = datetime.fromisoformat(od[:10]).date()
                if oldest_p0_opened is None or opened < oldest_p0_opened:
                    oldest_p0_opened = opened
            except Exception:
                pass

    if prio_filter and p not in prio_filter:
        continue
    if effort_filter and e not in effort_filter:
        continue
    if domain_filter and d not in domain_filter:
        continue
    pickable += 1

oldest_age = (today - oldest_p0_opened).days if oldest_p0_opened else 0
print(pickable, p0_count, oldest_age)
PYEOF
            ) 2>/dev/null || { _pickable=0; _p0_count=0; _oldest_p0_age=0; }
        else
            _pickable=0; _p0_count=0; _oldest_p0_age=0
        fi
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" fleet_queue_depth \
            "pickable_count=${_pickable:-0}" \
            "p0_count=${_p0_count:-0}" \
            "oldest_p0_age_days=${_oldest_p0_age:-0}" 2>/dev/null || true
        _last_queue_emit=$SECONDS
    fi

    # INFRA-565: reap stale fleet-* leases every 30 min
    if (( SECONDS - _last_reap >= 1800 )); then
        _reaped=0
        for _lease in "$REPO_ROOT/.chump-locks"/fleet-*.json; do
            [[ -f "$_lease" ]] || continue
            _sid="$(basename "$_lease" .json)"
            _pid="$(printf '%s' "$_sid" | rev | cut -d- -f2 | rev)"
            _dead=0
            if [[ "$_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_pid" 2>/dev/null; then
                _dead=1
            fi
            _hb_stale=0
            _hb_age="$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(open('$_lease'))
    hb = d.get('heartbeat_at') or d.get('heartbeat') or d.get('taken_at') or ''
    if hb:
        t = datetime.fromisoformat(hb.rstrip('Z')).replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - t).total_seconds()
        print(int(age))
    else:
        print(0)
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
            if (( _hb_age > 7200 )); then
                _hb_stale=1
            fi
            if (( _dead || _hb_stale )); then
                _reason="pid_dead"
                (( _hb_stale )) && _reason="heartbeat_stale_${_hb_age}s"
                echo "[control] reaping stale fleet lease ($_reason): $(basename "$_lease")"
                "$REPO_ROOT/scripts/dev/ambient-emit.sh" fleet_lease_reaped \
                    "session_id=${_sid}" "reason=${_reason}" 2>/dev/null || true
                rm -f "$_lease"
                (( _reaped++ )) || true
            fi
        done
        if (( _reaped > 0 )); then
            echo "[control] reaped $_reaped stale fleet lease(s)"
        fi
        _last_reap=$SECONDS
    fi

    sleep "$REFRESH_S"
done
