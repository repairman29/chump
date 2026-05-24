#!/usr/bin/env bash
# opus-digest-forecast.sh — META-092
#
# Emit a predictive operator digest for an Opus shepherd, replacing the older
# descriptive "STATUS TICK ~N: shipped X" pattern with forward-looking signal
# the operator can decide against.
#
# Required predictive signals per send (≥2):
#   (a) queue-exhaustion forecast — "queue exhausts in ~N hr at current pick rate"
#   (b) sibling-takeover trigger  — "INFRA-X claim silent N min; takeover by T"
#   (c) session-budget burn       — "token spend Y/hr, limit hit by HH:MM"
#   (d) ship-rate delta vs fleet  — "my rate Z/hr vs fleet B/hr; bottleneck=W"
#
# Output: digest text on stdout (pipe into broadcast.sh).
#
# Usage:
#   bash scripts/coord/opus-digest-forecast.sh
#   bash scripts/coord/opus-digest-forecast.sh --json   # structured fields
#   bash scripts/coord/opus-digest-forecast.sh --window-h 24  # ship-rate window

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-$(cat .chump-locks/.wt-session-id 2>/dev/null || echo opus-unknown)}"

# Bypass: fall back to descriptive-only mode (legacy)
if [[ "${CHUMP_OPUS_DIGEST_FORECAST:-1}" == "0" ]]; then
    echo "STATUS TICK: descriptive-only mode (CHUMP_OPUS_DIGEST_FORECAST=0)"
    exit 0
fi

JSON_OUT=0
WINDOW_H=24
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)         JSON_OUT=1; shift ;;
        --window-h)     WINDOW_H="$2"; shift 2 ;;
        --window-h=*)   WINDOW_H="${1#--window-h=}"; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "opus-digest-forecast: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

export CHUMP_DIGEST_REPO_ROOT="$REPO_ROOT"
export CHUMP_DIGEST_AMBIENT="$AMBIENT"
export CHUMP_DIGEST_SESSION="$SESSION_ID"
export CHUMP_DIGEST_JSON="$JSON_OUT"
export CHUMP_DIGEST_WINDOW_H="$WINDOW_H"

python3 <<'PYEOF'
import datetime, json, os, re, subprocess, sys

REPO = os.environ["CHUMP_DIGEST_REPO_ROOT"]
AMBIENT = os.environ["CHUMP_DIGEST_AMBIENT"]
SESSION = os.environ["CHUMP_DIGEST_SESSION"]
JSON_OUT = os.environ["CHUMP_DIGEST_JSON"] == "1"
WINDOW_H = float(os.environ.get("CHUMP_DIGEST_WINDOW_H","24"))

NOW = datetime.datetime.now(datetime.timezone.utc)
CUTOFF = (NOW - datetime.timedelta(hours=WINDOW_H)).strftime("%Y-%m-%dT%H:%M:%SZ")

# ── (a) Queue-exhaustion forecast ──────────────────────────────────────────
gaps_out = subprocess.run(
    ["chump","gap","list","--status","open","--json"],
    capture_output=True, text=True,
).stdout
try:
    open_gaps = json.loads(gaps_out)
except Exception:
    open_gaps = []
safe_pickable = [
    g for g in open_gaps
    if g.get("priority") == "P1" and g.get("effort") in ("xs","s")
]
pickable_n = len(safe_pickable)

# Fleet ship rate (last WINDOW_H hours)
gh = subprocess.run(
    ["gh","pr","list","--state","merged","--limit","100","--json","mergedAt"],
    capture_output=True, text=True,
)
try:
    merged = json.loads(gh.stdout)
except Exception:
    merged = []
cutoff_dt = NOW - datetime.timedelta(hours=WINDOW_H)
recent_merges = [m for m in merged if m.get("mergedAt") and
                 datetime.datetime.fromisoformat(m["mergedAt"].replace("Z","+00:00")) > cutoff_dt]
fleet_rate_per_hr = len(recent_merges) / WINDOW_H if WINDOW_H > 0 else 0
# Queue exhaustion: pickable_n / fleet_rate_per_hr (hours)
if fleet_rate_per_hr > 0:
    exhaust_hr = round(pickable_n / fleet_rate_per_hr, 1)
else:
    exhaust_hr = None

# ── (b) Sibling takeover trigger ───────────────────────────────────────────
lock_dir = os.path.join(REPO, ".chump-locks")
silent_claims = []
if os.path.isdir(lock_dir):
    for fn in sorted(os.listdir(lock_dir)):
        if not fn.startswith("claim-") or not fn.endswith(".json"): continue
        path = os.path.join(lock_dir, fn)
        try:
            d = json.load(open(path))
            # File mtime as proxy for last-progress; if older than 30 min, candidate
            mtime = datetime.datetime.fromtimestamp(os.path.getmtime(path), tz=datetime.timezone.utc)
            age_min = round((NOW - mtime).total_seconds() / 60, 1)
            if age_min >= 30:
                silent_claims.append({"gap_id": d.get("gap_id","?"), "age_min": age_min})
        except Exception:
            pass

# ── (c) Session-budget burn ────────────────────────────────────────────────
# Heuristic: count my session's broadcasts in ambient as a proxy for activity
my_events = 0
try:
    with open(AMBIENT) as f:
        for line in f:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("session") == SESSION and obj.get("ts","") > CUTOFF:
                my_events += 1
except FileNotFoundError:
    pass
# Crude burn-rate: events per hour for this session
events_per_hr = my_events / WINDOW_H if WINDOW_H > 0 else 0

# ── (d) My ship rate vs fleet baseline ──────────────────────────────────────
# Count my session's DONE broadcasts to orchestrator-opus
my_ships = 0
try:
    with open(AMBIENT) as f:
        for line in f:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if (obj.get("session") == SESSION
                and (obj.get("event") == "DONE" or obj.get("kind") == "DONE")
                and obj.get("ts","") > CUTOFF):
                my_ships += 1
except FileNotFoundError:
    pass
my_rate_per_hr = round(my_ships / WINDOW_H, 2) if WINDOW_H > 0 else 0
rate_delta = round(my_rate_per_hr - fleet_rate_per_hr, 2)

# ── Render forecast lines ──────────────────────────────────────────────────
forecast_lines = []
if exhaust_hr is not None:
    forecast_lines.append(f"queue exhausts in ~{exhaust_hr}hr at fleet {fleet_rate_per_hr:.2f}/hr (pickable={pickable_n})")
else:
    forecast_lines.append(f"queue stale (fleet rate ~0/hr last {WINDOW_H:.0f}h, pickable={pickable_n})")
if silent_claims:
    s = silent_claims[0]
    forecast_lines.append(f"sibling {s['gap_id']} silent {s['age_min']:.0f}min — takeover candidate")
if events_per_hr > 30:
    forecast_lines.append(f"my activity {events_per_hr:.0f} events/hr — high-churn pace")
forecast_lines.append(f"my-ship rate {my_rate_per_hr}/hr vs fleet {fleet_rate_per_hr:.2f}/hr (Δ={rate_delta:+})")

result = {
    "ts": NOW.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "session": SESSION,
    "pickable_n": pickable_n,
    "fleet_rate_per_hr": round(fleet_rate_per_hr, 2),
    "queue_exhaust_hr": exhaust_hr,
    "silent_claims": silent_claims,
    "my_session_events_per_hr": round(events_per_hr, 1),
    "my_ship_rate_per_hr": my_rate_per_hr,
    "ship_rate_delta_vs_fleet": rate_delta,
    "forecast_lines": forecast_lines,
}

if JSON_OUT:
    print(json.dumps(result, indent=2))
else:
    print("STATUS TICK: " + " | ".join(["FORECAST:"] + forecast_lines))
PYEOF
