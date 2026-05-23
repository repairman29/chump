#!/usr/bin/env bash
# scripts/dev/chump-dashboard-tui.sh — INFRA-1894
#
# One-shot terminal dashboard for the live state of the Chump fleet.
# Pairs with scripts/dev/lightning-demo-timeline.sh (historical) and
# docs/DEMO_5MIN.md (the pitch wrapper) to give an operator three views:
#
#   chump-dashboard-tui.sh             — live snapshot, screenshot-ready
#   lightning-demo-timeline.sh         — last-10 PR wall-clock retrospective
#   cat docs/DEMO_5MIN.md               — the 5-minute pitch
#
# Five sections, each < 10 lines, fits in 80x40 terminal.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

JSON=0
WATCH=0
WATCH_INTERVAL_S=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --watch) WATCH=1; shift ;;
        --interval) WATCH_INTERVAL_S="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "chump-dashboard-tui: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

# ── Section A: ships + lightning ──────────────────────────────────────────────
section_ships() {
    local lightning_json today_ships median p10 p90 sample_size
    if [[ -x "$REPO_ROOT/scripts/dev/lightning-demo-timeline.sh" ]]; then
        lightning_json=$("$REPO_ROOT/scripts/dev/lightning-demo-timeline.sh" --json 2>/dev/null || echo '{}')
    else
        lightning_json='{}'
    fi
    today_ships=$(echo "$lightning_json" | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('summary',{}); print(s.get('ship_count', 0))" 2>/dev/null || echo "?")
    median=$(echo "$lightning_json" | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('summary',{}); print(s.get('median_min') or '?')" 2>/dev/null || echo "?")
    p10=$(echo "$lightning_json" | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('summary',{}); print(s.get('p10_min') or '?')" 2>/dev/null || echo "?")
    p90=$(echo "$lightning_json" | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('summary',{}); print(s.get('p90_min') or '?')" 2>/dev/null || echo "?")
    sample_size="$today_ships"
    echo "──── SHIPS (last ${sample_size}) ────────────────────────────────────────"
    printf "  count: %s   median: %s min   p10: %s   p90: %s\n" "$today_ships" "$median" "$p10" "$p90"
}

# ── Section B: active leases ──────────────────────────────────────────────────
section_leases() {
    echo "──── ACTIVE LEASES ────────────────────────────────────────────────────"
    if command -v chump >/dev/null 2>&1; then
        chump --leases 2>/dev/null | head -8 | sed 's/^/  /' || echo "  (chump --leases failed)"
    else
        echo "  (no chump binary on PATH)"
    fi
}

# ── Section C: inbox unread ───────────────────────────────────────────────────
section_inbox() {
    echo "──── INBOX ────────────────────────────────────────────────────────────"
    if [[ -x "$REPO_ROOT/scripts/coord/chump-inbox.sh" ]]; then
        local count
        count=$("$REPO_ROOT/scripts/coord/chump-inbox.sh" count 2>/dev/null || echo "?")
        printf "  unread for %s: %s\n" "${CHUMP_SESSION_ID:-(no session set)}" "$count"
    else
        echo "  (no chump-inbox.sh found)"
    fi
}

# ── Section D: pillar breakdown ───────────────────────────────────────────────
section_pillars() {
    echo "──── PILLAR PICKABLE (P0|P1, xs|s, no-deps) ───────────────────────────"
    if command -v chump >/dev/null 2>&1; then
        chump gap audit-priorities --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    pickable = d.get('pickable_by_pillar', d.get('pillar_pickable', {})) or {}
    if not pickable:
        print('  (no pickable_by_pillar data)')
    else:
        order = ['EFFECTIVE', 'CREDIBLE', 'RESILIENT', 'ZERO-WASTE', 'MISSION']
        parts = []
        for p in order:
            n = pickable.get(p) or pickable.get(p.lower())
            if n is not None:
                parts.append(f'{p}={n}')
        print('  ' + '   '.join(parts) if parts else '  (no data)')
except Exception as e:
    print(f'  (audit-priorities parse failed: {e})')
" 2>/dev/null || echo "  (audit-priorities failed)"
    else
        echo "  (no chump binary on PATH)"
    fi
}

# ── Section E: last 5 ALERT/WARN/STUCK ──────────────────────────────────────
section_alerts() {
    echo "──── LAST 5 ALERT/WARN/STUCK ──────────────────────────────────────────"
    if [[ -r "$AMBIENT_LOG" ]]; then
        AMBIENT_LOG="$AMBIENT_LOG" python3 <<'PYEOF'
import json, os
path = os.environ['AMBIENT_LOG']
hits = []
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            ev = e.get('event', '')
            kind = e.get('kind', '')
            if ev in ('ALERT','WARN','STUCK') or kind in ('graphql_exhausted','silent_agent','pr_stuck','fleet_wedge'):
                hits.append((e.get('ts',''), ev or kind, (e.get('reason') or e.get('note') or '')[:60]))
    for ts, k, r in hits[-5:]:
        print(f"  [{ts}] {k}: {r}")
    if not hits:
        print('  (none recently)')
except Exception as e:
    print(f'  (ambient read failed: {e})')
PYEOF
    else
        echo "  (no ambient.jsonl)"
    fi
}

render_human() {
    clear 2>/dev/null || true
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║  Chump Fleet Dashboard — $ts                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    section_ships
    section_leases
    section_inbox
    section_pillars
    section_alerts
    echo
    echo "  (refresh: bash $0; watch: bash $0 --watch)"
}

render_json() {
    local lightning_json leases_text inbox_count
    lightning_json='{}'
    if [[ -x "$REPO_ROOT/scripts/dev/lightning-demo-timeline.sh" ]]; then
        lightning_json=$("$REPO_ROOT/scripts/dev/lightning-demo-timeline.sh" --json 2>/dev/null || echo '{}')
    fi
    leases_text=$(chump --leases 2>/dev/null | head -20 || echo "")
    inbox_count="0"
    if [[ -x "$REPO_ROOT/scripts/coord/chump-inbox.sh" ]]; then
        inbox_count=$("$REPO_ROOT/scripts/coord/chump-inbox.sh" count 2>/dev/null || echo "0")
    fi
    LIGHTNING_JSON="$lightning_json" LEASES_TEXT="$leases_text" INBOX_COUNT="$inbox_count" \
        python3 <<'PYEOF'
import json, os
out = {
    'ts': __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'lightning': json.loads(os.environ.get('LIGHTNING_JSON') or '{}'),
    'leases_text': os.environ.get('LEASES_TEXT', ''),
    'inbox_unread': int(os.environ.get('INBOX_COUNT', '0') or '0'),
    'session_id': os.environ.get('CHUMP_SESSION_ID', ''),
}
print(json.dumps(out, separators=(',', ':')))
PYEOF
}

if [[ "$JSON" -eq 1 ]]; then
    render_json
    exit 0
fi

if [[ "$WATCH" -eq 1 ]]; then
    while true; do
        render_human
        sleep "$WATCH_INTERVAL_S"
    done
else
    render_human
fi
