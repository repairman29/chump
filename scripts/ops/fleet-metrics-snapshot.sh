#!/usr/bin/env bash
# scripts/ops/fleet-metrics-snapshot.sh — INFRA-900
#
# Reads ambient.jsonl + state.db and emits kind=fleet_metrics_snapshot with:
#   ts, ship_rate_24h, waste_rate_24h, cycle_time_p50_h, active_gaps, p0_count
#
# Usage:
#   fleet-metrics-snapshot.sh             # emit to ambient.jsonl + human output
#   fleet-metrics-snapshot.sh --json      # print JSON to stdout only (no ambient emit)
#   fleet-metrics-snapshot.sh --no-emit   # compute and print but skip ambient write
#
# Environment:
#   CHUMP_AMBIENT_LOG   path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   CHUMP_STATE_DB      path to state.db (default: .chump/state.db)
#   CHUMP_BIN           path to chump binary (default: chump)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
CHUMP_BIN="${CHUMP_BIN:-chump}"
WANT_JSON=0
NO_EMIT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    WANT_JSON=1; NO_EMIT=1; shift ;;
        --no-emit) NO_EMIT=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

python3 - "$AMBIENT" "$STATE_DB" "$WANT_JSON" "$NO_EMIT" "$REPO_ROOT" "$CHUMP_BIN" <<'PYEOF'
import sys
import json
import subprocess
import os
from datetime import datetime, timezone, timedelta

ambient_path = sys.argv[1]
state_db     = sys.argv[2]
want_json    = sys.argv[3] == "1"
no_emit      = sys.argv[4] == "1"
repo_root    = sys.argv[5]
chump_bin    = sys.argv[6]

now = datetime.now(timezone.utc)
cutoff_24h = now - timedelta(hours=24)

shipped_24h = 0
claimed_24h = 0
elapsed_secs_shipped = []

try:
    with open(ambient_path) as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                d = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ts_str = d.get("ts", "")
            if not ts_str:
                continue
            try:
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts < cutoff_24h:
                continue
            kind = d.get("kind", d.get("event", ""))
            if kind == "session_end" and d.get("outcome") == "shipped":
                shipped_24h += 1
                elapsed = d.get("elapsed_seconds")
                if elapsed is not None:
                    try:
                        elapsed_secs_shipped.append(float(elapsed))
                    except (TypeError, ValueError):
                        pass
            elif kind == "gap_claimed":
                claimed_24h += 1
except FileNotFoundError:
    pass

# ship_rate_24h: merged PRs / opened PRs (gap_claimed as proxy for opened)
if claimed_24h > 0:
    ship_rate_24h = shipped_24h / claimed_24h
elif shipped_24h > 0:
    ship_rate_24h = 1.0
else:
    ship_rate_24h = 0.0

# waste_rate_24h: waste incidents / (shipped + waste incidents), from chump waste-tally
waste_incidents = 0
try:
    env = dict(os.environ)
    env.setdefault("CHUMP_REPO", repo_root)
    env.setdefault("CHUMP_LOCK_DIR", str(os.path.dirname(os.path.abspath(ambient_path))))
    result = subprocess.run(
        [chump_bin, "waste-tally", "--since", "24h", "--json"],
        capture_output=True, text=True, timeout=30, env=env
    )
    if result.returncode == 0 and result.stdout.strip():
        wdata = json.loads(result.stdout)
        waste_incidents = int(wdata.get("total_incidents", 0))
except Exception:
    pass

total_denominator = shipped_24h + waste_incidents
waste_rate_24h = (waste_incidents / total_denominator) if total_denominator > 0 else 0.0

# cycle_time_p50_h: median elapsed_seconds / 3600 across shipped sessions
def p50(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    mid = n // 2
    return (s[mid - 1] + s[mid]) / 2.0 if n % 2 == 0 else float(s[mid])

p50_secs = p50(elapsed_secs_shipped)
cycle_time_p50_h = round(p50_secs / 3600.0, 3) if p50_secs is not None else None

# active_gaps + p0_count from state.db
active_gaps = 0
p0_count = 0
try:
    import sqlite3
    conn = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
    active_gaps = conn.execute(
        "SELECT COUNT(*) FROM gaps WHERE status='open'"
    ).fetchone()[0]
    p0_count = conn.execute(
        "SELECT COUNT(*) FROM gaps WHERE status='open' AND priority='P0'"
    ).fetchone()[0]
    conn.close()
except Exception:
    pass

ts_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
snapshot = {
    "ts": ts_iso,
    "kind": "fleet_metrics_snapshot",
    "ship_rate_24h": round(ship_rate_24h, 4),
    "waste_rate_24h": round(waste_rate_24h, 4),
    "cycle_time_p50_h": cycle_time_p50_h,
    "active_gaps": active_gaps,
    "p0_count": p0_count,
}

line_out = json.dumps(snapshot)

if want_json:
    print(line_out)
else:
    print(f"fleet metrics snapshot:")
    print(f"  ship_rate_24h    = {snapshot['ship_rate_24h']:.4f}")
    print(f"  waste_rate_24h   = {snapshot['waste_rate_24h']:.4f}")
    ct = snapshot['cycle_time_p50_h']
    print(f"  cycle_time_p50_h = {ct if ct is not None else 'n/a'}")
    print(f"  active_gaps      = {snapshot['active_gaps']}")
    print(f"  p0_count         = {snapshot['p0_count']}")

if not no_emit:
    try:
        amb_dir = os.path.dirname(os.path.abspath(ambient_path))
        os.makedirs(amb_dir, exist_ok=True)
        with open(ambient_path, "a") as f:
            f.write(line_out + "\n")
        print(
            f"[fleet-metrics-snapshot] emitted kind=fleet_metrics_snapshot → {ambient_path}",
            file=sys.stderr
        )
    except Exception as e:
        print(
            f"[fleet-metrics-snapshot] WARNING: could not write to {ambient_path}: {e}",
            file=sys.stderr
        )
PYEOF
