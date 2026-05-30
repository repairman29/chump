#!/usr/bin/env bash
# opus-shepherd-triage.sh — META-091
#
# Session-start structured triage pass for an Opus shepherd /loop. Runs
# BEFORE the first inbox-read step so the session lands with a written
# game-plan instead of polling-and-reacting tick-by-tick.
#
# Five sections (in order):
#   1. Ghost-gap sweep         — status:open whose canonical-close PR is merged
#   2. Ambient signature stats — last-24h event-kind histogram + back-off check
#   3. Sibling lease inventory — gap-id + paths per active claim
#   4. Pickable diff           — P1/xs+s gaps NOT in any sibling lease
#   5. Written game-plan       — 3-bullet operator-readable plan to ambient + a2a
#
# Output: human-readable to stdout; structured kind=opus_shepherd_triage event
# to ambient.jsonl; a2a WARN broadcast to operator-<id>.
#
# Usage:
#   bash scripts/coord/opus-shepherd-triage.sh
#   bash scripts/coord/opus-shepherd-triage.sh --no-broadcast  # local only
#   bash scripts/coord/opus-shepherd-triage.sh --json          # machine-readable

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
OPERATOR_ID="${CHUMP_OPERATOR_ID:-$(cat .chump/operator_id 2>/dev/null || echo operator-unknown)}"
SESSION_ID="${CHUMP_SESSION_ID:-$(cat .chump-locks/.wt-session-id 2>/dev/null || echo opus-unknown)}"

# Bypass support (per META-091 AC #6)
if [[ "${CHUMP_OPUS_SHEPHERD_TRIAGE:-1}" == "0" ]]; then
    python3 -c "import json,datetime; print(json.dumps({'ts':datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),'kind':'opus_shepherd_triage_skipped','session':'$SESSION_ID','reason':'CHUMP_OPUS_SHEPHERD_TRIAGE=0'},separators=(',',':')))" >> "$AMBIENT"
    echo "[opus-shepherd-triage] skipped (CHUMP_OPUS_SHEPHERD_TRIAGE=0)" >&2
    exit 0
fi

BROADCAST=1
JSON_OUT=0

# INFRA-2238: fleet-autopilot.sh wires curator panes to call
# `<script> tick` and `<script> heartbeat`. Recognize these two
# positional subcommands first so the autopilot wrapper stops silently
# no-op'ing every 5 minutes. `tick` runs the triage cycle as a no-flag
# invocation; `heartbeat` emits an ambient event and exits.
if [[ "${1:-}" == "tick" ]]; then
    shift
elif [[ "${1:-}" == "heartbeat" ]]; then
    python3 -c "
import datetime, json
print(json.dumps({
    'ts': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'kind': 'shepherd_heartbeat',
    'session': '$SESSION_ID',
    'role': 'curator-opus-shepherd-triage',
}, separators=(',', ':')))
" >> "$AMBIENT" 2>/dev/null || true
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-broadcast) BROADCAST=0; shift ;;
        --json)         JSON_OUT=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "opus-shepherd-triage: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

# INFRA-2262: inject ambient digest before triage so bash daemon is not deaf to fleet wire
_inject_script="$(dirname "$0")/ambient-context-inject.sh"
if [[ -x "$_inject_script" ]]; then
    "$_inject_script" --tick-preamble --role shepherd 2>/dev/null || true
fi

export CHUMP_TRIAGE_REPO_ROOT="$REPO_ROOT"
export CHUMP_TRIAGE_AMBIENT="$AMBIENT"
export CHUMP_TRIAGE_OPERATOR="$OPERATOR_ID"
export CHUMP_TRIAGE_SESSION="$SESSION_ID"
export CHUMP_TRIAGE_JSON="$JSON_OUT"

# All five sections rendered via Python — easier JSON parsing than bash.
# Python writes summary to $CHUMP_TRIAGE_SUMMARY for the bash broadcast step,
# and prints human/json output to stdout for the caller/test.
SUMMARY_FILE=$(mktemp)
trap "rm -f '$SUMMARY_FILE'" EXIT
export CHUMP_TRIAGE_SUMMARY="$SUMMARY_FILE"
python3 <<'PYEOF'
import datetime, json, os, re, subprocess, sys

REPO = os.environ["CHUMP_TRIAGE_REPO_ROOT"]
AMBIENT = os.environ["CHUMP_TRIAGE_AMBIENT"]
SESSION = os.environ["CHUMP_TRIAGE_SESSION"]
JSON_OUT = os.environ["CHUMP_TRIAGE_JSON"] == "1"

NOW = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
CUTOFF_24H = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
CUTOFF_30M = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ")

# ── 1. Ghost-gap sweep ─────────────────────────────────────────────────────
ghosts = []
gaps_out = subprocess.run(["chump","gap","list","--status","open","--json"], capture_output=True, text=True).stdout
try:
    open_gaps = json.loads(gaps_out)
except Exception:
    open_gaps = []
p1 = [g for g in open_gaps if g.get("priority") == "P1"][:40]
for g in p1:
    gid = g.get("id","")
    if not gid: continue
    r = subprocess.run(
        ["gh","pr","list","--search",f"in:title {gid}","--state","merged","--limit","1","--json","number,mergedAt,title"],
        capture_output=True, text=True, timeout=30,
    )
    try:
        prs = json.loads(r.stdout)
        if prs and prs[0].get("mergedAt"):
            t = prs[0].get("title","")[:80]
            # Strict close-format filter (avoid false positives like the retro's INFRA-1909 hit)
            if f"({gid})" in t or t.startswith(f"{gid}:") or f"{gid}:" in t[:50]:
                ghosts.append({"gap_id": gid, "pr": prs[0]["number"], "title": t})
    except Exception:
        pass

# ── 2. Ambient signature stats ─────────────────────────────────────────────
from collections import Counter
event_kinds = Counter()
back_off = {"fleet_wedge": 0, "silent_agent": 0, "pr_stuck_cluster": 0}
try:
    with open(AMBIENT) as f:
        for line in f:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            ts = str(obj.get("ts",""))
            if ts < CUTOFF_24H: continue
            k = obj.get("kind") or obj.get("event") or ""
            event_kinds[k] += 1
            # Back-off triggers in 30-min window
            if ts >= CUTOFF_30M and k in back_off:
                back_off[k] += 1
except FileNotFoundError:
    pass
top_kinds = event_kinds.most_common(10)

# ── 3. Sibling lease inventory ─────────────────────────────────────────────
leases = []
lock_dir = os.path.join(REPO, ".chump-locks")
if os.path.isdir(lock_dir):
    for fn in sorted(os.listdir(lock_dir)):
        if not fn.startswith("claim-") or not fn.endswith(".json"): continue
        try:
            d = json.load(open(os.path.join(lock_dir, fn)))
            leases.append({"gap_id": d.get("gap_id","?"), "paths": d.get("paths","*"), "file": fn})
        except Exception:
            pass

# ── 4. Pickable diff (P1/xs+s NOT in any sibling lease) ────────────────────
held_gaps = {l["gap_id"] for l in leases}
pickable = []
for g in open_gaps:
    if g.get("priority") != "P1": continue
    if g.get("effort") not in ("xs","s"): continue
    if g.get("id") in held_gaps: continue
    pickable.append({"gap_id": g.get("id"), "title": g.get("title","")[:80]})
pickable = pickable[:10]

# ── 5. Game-plan synthesis ─────────────────────────────────────────────────
plan = []
if ghosts:
    plan.append(f"Reconcile {len(ghosts)} ghost-gaps (CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 chump gap ship ... batch)")
back_off_total = sum(back_off.values())
if back_off_total >= 3:
    plan.append(f"BACK-OFF: {back_off_total} triggers in last 30m — pause dispatch this tick, report to operator")
elif pickable:
    plan.append(f"Pickable surface has {len(pickable)} safe P1/xs+s candidates; top: {pickable[0]['gap_id'] if pickable else 'none'}")
else:
    plan.append("Pickable surface thin; switch to follow-up gap filing or operator-driven docs")
plan.append(f"Sibling leases: {len(leases)} active — avoid path collisions")

# Render
result = {
    "ts": NOW,
    "session": SESSION,
    "ghosts": ghosts,
    "event_kinds_24h": dict(top_kinds),
    "back_off_30m": back_off,
    "leases": leases,
    "pickable_top": pickable,
    "plan": plan,
}

if JSON_OUT:
    print(json.dumps(result, indent=2))
else:
    print("=== Opus shepherd session-start triage ===")
    print(f"  ts: {NOW}  session: {SESSION}")
    print()
    print(f"[1] Ghost-gap sweep: {len(ghosts)} candidates")
    for g in ghosts[:5]:
        print(f"    {g['gap_id']:14s} → #{g['pr']}")
    if len(ghosts) > 5: print(f"    ... ({len(ghosts)-5} more)")
    print()
    print("[2] Ambient signatures (last 24h, top kinds):")
    for k, n in top_kinds[:5]:
        print(f"    {n:5d}  {k}")
    print(f"    back-off (30m): {back_off}")
    print()
    print(f"[3] Sibling leases: {len(leases)} active")
    for l in leases[:5]:
        print(f"    {l['gap_id']:14s} paths={l['paths']}")
    print()
    print(f"[4] Pickable P1/xs+s safe: {len(pickable)}")
    for p in pickable[:3]:
        print(f"    {p['gap_id']:14s} {p['title']}")
    print()
    print("[5] Game-plan:")
    for i, b in enumerate(plan, 1):
        print(f"    {i}. {b}")

# Emit structured event regardless of mode
payload = {
    "ts": NOW,
    "kind": "opus_shepherd_triage",
    "session": SESSION,
    "ghost_count": len(ghosts),
    "back_off_30m_total": back_off_total,
    "lease_count": len(leases),
    "pickable_count": len(pickable),
    "plan": plan,
}
try:
    with open(AMBIENT, "a") as f:
        f.write(json.dumps(payload, separators=(",", ":")) + "\n")
except Exception:
    pass

# Emit kind=opus_shepherd_plan separately so operators can filter
plan_payload = {
    "ts": NOW,
    "kind": "opus_shepherd_plan",
    "session": SESSION,
    "plan": plan,
}
try:
    with open(AMBIENT, "a") as f:
        f.write(json.dumps(plan_payload, separators=(",", ":")) + "\n")
except Exception:
    pass

# Write summary to the bash-side file (separate from stdout so test JSON parses cleanly)
summary_path = os.environ.get("CHUMP_TRIAGE_SUMMARY", "")
if summary_path:
    try:
        with open(summary_path, "w") as f:
            json.dump({"ghost_count": len(ghosts), "back_off_total": back_off_total, "lease_count": len(leases), "pickable_count": len(pickable), "plan": plan}, f)
    except Exception:
        pass
PYEOF

# Summary written by python to $SUMMARY_FILE
SUMMARY_JSON=$(cat "$SUMMARY_FILE" 2>/dev/null || echo "{}")

if [[ "$BROADCAST" == "1" ]]; then
    if [[ -x "$REPO_ROOT/scripts/coord/broadcast.sh" ]]; then
        PLAN=$(echo "$SUMMARY_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(' | '.join(d.get('plan',[])))" 2>/dev/null || echo "(plan unavailable)")
        GHOST=$(echo "$SUMMARY_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ghost_count',0))" 2>/dev/null || echo 0)
        CHUMP_SESSION_ID="$SESSION_ID" "$REPO_ROOT/scripts/coord/broadcast.sh" --to "$OPERATOR_ID" WARN \
            "SHEPHERD-TRIAGE: ghosts=$GHOST. PLAN: $PLAN" >/dev/null 2>&1 || true
    fi
fi
