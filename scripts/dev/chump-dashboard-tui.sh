#!/usr/bin/env bash
# scripts/dev/chump-dashboard-tui.sh — INFRA-1894
#
# One-shot terminal dashboard for the Chump operator pitch (META-067 Track 3).
# Fits in a single 80x40 terminal screen. No curses, no polling.
#
# Sections:
#   (a) Today's shipping — count + median ship time (lightning-demo-timeline.sh --json)
#   (b) Active leases   — table from .chump-locks/claim-*.json
#   (c) Inbox unread    — count from chump-inbox.sh count
#   (d) Pillar pickable — per-pillar open P1 xs|s|m gap count (chump gap list)
#   (e) Recent alerts   — last 5 ALERT/WARN/STUCK events from ambient.jsonl
#
# Usage:
#   chump-dashboard-tui.sh              # one-shot render to stdout, exit 0
#   chump-dashboard-tui.sh --json       # same data as JSON envelope
#   chump-dashboard-tui.sh --watch [--interval N]  # redraw every N seconds (default 5)

set -uo pipefail

# Resolve repo root without relying on cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
CHUMP_BIN="${CHUMP_BIN:-$(command -v chump 2>/dev/null || echo "$MAIN_REPO/target/debug/chump")}"

JSON=0
WATCH=0
WATCH_INTERVAL_S=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)        JSON=1; shift ;;
        --watch)       WATCH=1; shift ;;
        --interval)    WATCH_INTERVAL_S="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,20p' "$0"
            exit 0
            ;;
        *) printf 'chump-dashboard-tui: unknown flag "%s"\n' "$1" >&2; exit 2 ;;
    esac
done

# ── Section A: ships ──────────────────────────────────────────────────────────
_section_a_data() {
    local today_ships="?" median="?"
    local timeline="$MAIN_REPO/scripts/dev/lightning-demo-timeline.sh"
    if [[ -x "$timeline" ]]; then
        local raw
        raw="$("$timeline" --json 2>/dev/null || echo '{}')"
        today_ships="$(printf '%s' "$raw" | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=d.get('summary',d)
v=s.get('ship_count') or s.get('today_ship_count') or s.get('count','?')
print(v)
" 2>/dev/null || echo '?')"
        median="$(printf '%s' "$raw" | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=d.get('summary',d)
v=s.get('median_min') or s.get('median_ship_time_min') or s.get('median','?')
print(v)
" 2>/dev/null || echo '?')"
    fi
    # fallback: git log count for today
    if [[ "$today_ships" == "?" ]]; then
        today_ships="$(git -C "$MAIN_REPO" log --after="midnight" --oneline origin/main 2>/dev/null | wc -l | tr -d ' ')"
    fi
    printf '%s\t%s' "$today_ships" "$median"
}

_section_a_render() {
    local data today_ships median
    data="$(_section_a_data)"
    today_ships="$(printf '%s' "$data" | cut -f1)"
    median="$(printf '%s' "$data" | cut -f2)"
    printf '  ships today: %-6s   median ship time: %s min\n' "$today_ships" "$median"
}

# ── Section B: active leases ──────────────────────────────────────────────────
_section_b_render() {
    local now_epoch any=0
    now_epoch="$(date +%s)"
    local f gap_id taken_at age_s age paths_raw paths
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        gap_id="$(python3 -c "import json; d=json.load(open('$f')); print(d.get('gap_id','?'))" 2>/dev/null || echo '?')"
        taken_at="$(python3 -c "import json; d=json.load(open('$f')); print(d.get('taken_at',''))" 2>/dev/null || echo '')"
        paths_raw="$(python3 -c "
import json
d=json.load(open('$f'))
ps=d.get('paths',[])
out=','.join(ps[:2])+(',...' if len(ps)>2 else '')
print(out[:32])
" 2>/dev/null || echo '')"
        if [[ -n "$taken_at" ]]; then
            local te
            # Use python3 for UTC-aware epoch to avoid macOS date -j localtime bug
            te="$(python3 -c "
from datetime import datetime, timezone
try:
    dt=datetime.strptime('$taken_at','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    import time; print(int(dt.timestamp()))
except Exception: print(0)
" 2>/dev/null || echo 0)"
            age_s=$(( now_epoch - te ))
            if (( age_s < 0 )); then age="0m"
            elif (( age_s < 3600 )); then age="$((age_s/60))m"
            else age="$((age_s/3600))h$((( age_s%3600)/60))m"; fi
        else
            age="?"
        fi
        printf '  %-20s %-7s %s\n' "$gap_id" "$age" "$paths_raw"
        any=1
    done < <(find "$LOCK_DIR" -maxdepth 1 -name 'claim-*.json' 2>/dev/null | sort)
    [[ "$any" -eq 0 ]] && printf '  (none)\n'
}

# ── Section C: inbox ──────────────────────────────────────────────────────────
_section_c_render() {
    local cnt="?"
    local inbox_sh="$MAIN_REPO/scripts/coord/chump-inbox.sh"
    if [[ -x "$inbox_sh" ]]; then
        cnt="$("$inbox_sh" count 2>/dev/null || echo '?')"
    fi
    printf '  unread: %s\n' "$cnt"
}

# ── Section D: pillar pickable ────────────────────────────────────────────────
_pillar_pickable() {
    local gaps="" eff=0 cred=0 res=0 zw=0 miss=0
    if [[ -x "$CHUMP_BIN" ]]; then
        gaps="$("$CHUMP_BIN" gap list --status open 2>/dev/null || true)"
        # first run sometimes prints "re-run to list" after auto-importing
        if printf '%s' "$gaps" | grep -q "re-run to list"; then
            gaps="$("$CHUMP_BIN" gap list --status open 2>/dev/null || true)"
        fi
        eff="$(printf '%s' "$gaps" | grep -cE '\bEFFECTIVE\b' 2>/dev/null || echo 0)"
        cred="$(printf '%s' "$gaps" | grep -cE '\bCREDIBLE\b' 2>/dev/null || echo 0)"
        res="$(printf '%s' "$gaps" | grep -cE '\bRESILIENT\b' 2>/dev/null || echo 0)"
        zw="$(printf '%s' "$gaps" | grep -cE '\bZERO-WASTE\b' 2>/dev/null || echo 0)"
        miss="$(printf '%s' "$gaps" | grep -cE '\bMISSION\b' 2>/dev/null || echo 0)"
    fi
    printf '%s\t%s\t%s\t%s\t%s' "$eff" "$cred" "$res" "$zw" "$miss"
}

_section_d_render() {
    local pd eff cred res zw miss
    pd="$(_pillar_pickable)"
    eff="$(printf '%s' "$pd" | cut -f1)"
    cred="$(printf '%s' "$pd" | cut -f2)"
    res="$(printf '%s' "$pd" | cut -f3)"
    zw="$(printf '%s' "$pd" | cut -f4)"
    miss="$(printf '%s' "$pd" | cut -f5)"
    printf '  EFFECTIVE=%-4s CREDIBLE=%-4s RESILIENT=%-4s ZERO-WASTE=%-4s MISSION=%-4s\n' \
        "$eff" "$cred" "$res" "$zw" "$miss"
}

# ── Section E: alerts ─────────────────────────────────────────────────────────
_section_e_render() {
    if [[ ! -r "$AMBIENT_LOG" ]]; then
        printf '  (no ambient.jsonl)\n'; return
    fi
    AMBIENT_LOG="$AMBIENT_LOG" python3 <<'PYEOF'
import json, os
path = os.environ['AMBIENT_LOG']
hits = []
try:
    with open(path) as f:
        lines = f.readlines()
    for line in lines[-200:]:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        ev   = e.get('event', '')
        kind = e.get('kind', '')
        if ev in ('ALERT', 'WARN', 'STUCK') \
           or kind in ('graphql_exhausted', 'silent_agent', 'pr_stuck', 'fleet_wedge'):
            ts  = e.get('ts', '')[:16]
            msg = str(e.get('reason') or e.get('note') or e.get('msg') or kind)[:52]
            hits.append((ts, ev or kind, msg))
    shown = hits[-5:]
    if shown:
        for ts, k, m in shown:
            print(f"  [{ts}] {k}: {m}")
    else:
        print("  (none recently)")
except Exception as ex:
    print(f"  (ambient read failed: {ex})")
PYEOF
}

# ── Human render ──────────────────────────────────────────────────────────────
render_human() {
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '┌──────────────────────────────────────────────────────────────────────────┐\n'
    printf '│  CHUMP DASHBOARD  %-56s│\n' "$ts"
    printf '├──────────────────────────────────────────────────────────────────────────┤\n'
    printf '│  (a) TODAY'\''S SHIPPING                                                     │\n'
    _section_a_render | while IFS= read -r r; do printf '│  %-74s│\n' "$r"; done
    printf '├──────────────────────────────────────────────────────────────────────────┤\n'
    printf '│  (b) ACTIVE LEASES                                                        │\n'
    printf '│  %-20s %-7s %-44s│\n' "GAP" "AGE" "PATHS"
    _section_b_render | while IFS= read -r r; do printf '│  %-74s│\n' "$r"; done
    printf '├──────────────────────────────────────────────────────────────────────────┤\n'
    printf '│  (c) INBOX UNREAD                                                         │\n'
    _section_c_render | while IFS= read -r r; do printf '│  %-74s│\n' "$r"; done
    printf '├──────────────────────────────────────────────────────────────────────────┤\n'
    printf '│  (d) PILLAR PICKABLE                                                      │\n'
    _section_d_render | while IFS= read -r r; do printf '│  %-74s│\n' "$r"; done
    printf '├──────────────────────────────────────────────────────────────────────────┤\n'
    printf '│  (e) RECENT ALERTS / WARN / STUCK (last 5)                                │\n'
    _section_e_render | head -5 | while IFS= read -r r; do printf '│  %-74s│\n' "$r"; done
    printf '└──────────────────────────────────────────────────────────────────────────┘\n'
}

# ── JSON render ───────────────────────────────────────────────────────────────
render_json() {
    # Section A
    local sd today_ships median
    sd="$(_section_a_data)"
    today_ships="$(printf '%s' "$sd" | cut -f1)"
    median="$(printf '%s' "$sd" | cut -f2)"

    # Section B: leases as JSON array
    local lease_json="["
    local first=1 f
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local entry
        entry="$(python3 -c "
import json
d=json.load(open('$f'))
print(json.dumps({'gap_id':d.get('gap_id','?'),'taken_at':d.get('taken_at',''),'paths':d.get('paths',[])}))
" 2>/dev/null || echo '')"
        [[ -z "$entry" ]] && continue
        [[ "$first" -eq 0 ]] && lease_json+=","
        lease_json+="$entry"
        first=0
    done < <(find "$LOCK_DIR" -maxdepth 1 -name 'claim-*.json' 2>/dev/null | sort)
    lease_json+="]"

    # Section C
    local inbox_cnt="?"
    local inbox_sh="$MAIN_REPO/scripts/coord/chump-inbox.sh"
    [[ -x "$inbox_sh" ]] && inbox_cnt="$("$inbox_sh" count 2>/dev/null || echo '?')"

    # Section D
    local pd eff cred res zw miss
    pd="$(_pillar_pickable)"
    eff="$(printf '%s' "$pd" | cut -f1)"
    cred="$(printf '%s' "$pd" | cut -f2)"
    res="$(printf '%s' "$pd" | cut -f3)"
    zw="$(printf '%s' "$pd" | cut -f4)"
    miss="$(printf '%s' "$pd" | cut -f5)"

    # Section E: alerts as JSON array
    local alert_json="[]"
    if [[ -r "$AMBIENT_LOG" ]]; then
        alert_json="$(AMBIENT_LOG="$AMBIENT_LOG" python3 <<'PYEOF'
import json, os
path = os.environ['AMBIENT_LOG']
hits = []
try:
    with open(path) as f:
        lines = f.readlines()
    for line in lines[-200:]:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        ev   = e.get('event', '')
        kind = e.get('kind', '')
        if ev in ('ALERT', 'WARN', 'STUCK') \
           or kind in ('graphql_exhausted', 'silent_agent', 'pr_stuck', 'fleet_wedge'):
            hits.append({'ts': e.get('ts',''), 'event': ev or kind,
                         'msg': str(e.get('reason') or e.get('note') or e.get('msg') or kind)})
    print(json.dumps(hits[-5:]))
except Exception as ex:
    print('[]')
PYEOF
)"
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    SHIP_COUNT="$today_ships" MEDIAN="$median" \
    LEASE_JSON="$lease_json" INBOX="$inbox_cnt" \
    EFF="$eff" CRED="$cred" RES="$res" ZW="$zw" MISS="$miss" \
    ALERTS="$alert_json" TS="$ts" \
    python3 <<'PYEOF'
import json, os
out = {
    "ts": os.environ["TS"],
    "shipping": {
        "today_ship_count": os.environ["SHIP_COUNT"],
        "median_ship_time_min": os.environ["MEDIAN"]
    },
    "leases": json.loads(os.environ.get("LEASE_JSON", "[]")),
    "inbox_unread": os.environ["INBOX"],
    "pillar_pickable": {
        "EFFECTIVE":  os.environ["EFF"],
        "CREDIBLE":   os.environ["CRED"],
        "RESILIENT":  os.environ["RES"],
        "ZERO_WASTE": os.environ["ZW"],
        "MISSION":    os.environ["MISS"]
    },
    "recent_alerts": json.loads(os.environ.get("ALERTS", "[]"))
}
print(json.dumps(out, indent=2))
PYEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ "$JSON" -eq 1 ]]; then
    render_json
elif [[ "$WATCH" -eq 1 ]]; then
    while true; do
        clear
        render_human
        sleep "$WATCH_INTERVAL_S"
    done
else
    render_human
fi
