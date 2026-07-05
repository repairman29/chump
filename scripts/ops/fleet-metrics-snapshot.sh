#!/usr/bin/env bash
# scripts/ops/fleet-metrics-snapshot.sh — INFRA-900
#
# Reads ambient.jsonl + state.db and emits kind=fleet_metrics_snapshot with:
#   ts, ship_rate_24h, waste_rate_24h, cycle_time_p50_h, active_gaps, p0_count
#
# Usage:
#   fleet-metrics-snapshot.sh [--json] [--dry-run] [--window HOURS]
#   chump fleet metrics [--json] [--dry-run] [--window HOURS]
#
# Options:
#   --json          Print the emitted JSON to stdout
#   --dry-run       Compute and print metrics; do NOT append to ambient.jsonl
#   --window HOURS  Look-back window (default: 24)
#
# Environment:
#   CHUMP_AMBIENT_LOG   Override path to ambient.jsonl
#   CHUMP_STATE_DB      Override path to state.db

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
WINDOW_H=24
WANT_JSON=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    WANT_JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --window)  WINDOW_H="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//; 1d'
            exit 0 ;;
        *) echo "fleet-metrics-snapshot: unknown option: $1" >&2; exit 1 ;;
    esac
done

python3 - "$AMBIENT" "$STATE_DB" "$WINDOW_H" "$WANT_JSON" "$DRY_RUN" "$REPO_ROOT" <<'PYEOF'
import sys, json, os, sqlite3
from datetime import datetime, timezone, timedelta

ambient_path = sys.argv[1]
state_db     = sys.argv[2]
window_h     = int(sys.argv[3])
want_json    = sys.argv[4] == "1"
dry_run      = sys.argv[5] == "1"
repo_root    = sys.argv[6]

now    = datetime.now(timezone.utc)
cutoff = now - timedelta(hours=window_h)
ts_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.rstrip("Z")).replace(tzinfo=timezone.utc)
    except (ValueError, AttributeError):
        return None

# ── ship_rate_24h: gap_shipped events / pr_opened in window ──────────────────
pr_opened = 0
pr_merged = 0
try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            ev_ts = parse_ts(ev.get("ts", ""))
            if ev_ts is None or ev_ts < cutoff:
                continue
            kind = ev.get("kind", "")
            if kind == "pr_opened":
                pr_opened += 1
            elif kind in ("gap_shipped", "pr_merged", "ship_landed"):
                pr_merged += 1
except FileNotFoundError:
    pass

if pr_opened > 0:
    ship_rate_24h = round(pr_merged / pr_opened, 3)
elif pr_merged > 0:
    ship_rate_24h = 1.0
else:
    ship_rate_24h = 0.0

# ── waste_rate_24h: try chump waste-tally --window Nh --json ─────────────────
waste_rate_24h = 0.0
import subprocess, shutil
chump_bin = os.path.join(repo_root, "target/debug/chump")
if not os.path.isfile(chump_bin):
    chump_bin = shutil.which("chump") or ""
if chump_bin and os.path.isfile(chump_bin):
    try:
        r = subprocess.run(
            [chump_bin, "waste-tally", "--window", f"{window_h}h", "--json"],
            capture_output=True, text=True, timeout=20, cwd=repo_root,
        )
        if r.returncode == 0 and r.stdout.strip():
            wdata = json.loads(r.stdout)
            if "waste_rate" in wdata:
                waste_rate_24h = round(float(wdata["waste_rate"]), 3)
    except Exception:
        pass

# ── cycle_time_p50_h: median open→closed from state.db ───────────────────────
cycle_time_p50_h = 0.0
if os.path.isfile(state_db):
    try:
        conn = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
        rows = conn.execute("""
            SELECT (julianday(closed_at) - julianday(created_at)) * 24.0
            FROM gaps
            WHERE status IN ('shipped','closed')
              AND closed_at IS NOT NULL
              AND created_at IS NOT NULL
              AND closed_at >= datetime('now', ?)
        """, (f"-{window_h} hours",)).fetchall()
        conn.close()
        vals = sorted(r[0] for r in rows if r[0] is not None and r[0] >= 0)
        if vals:
            n   = len(vals)
            mid = n // 2
            cycle_time_p50_h = round(
                (vals[mid - 1] + vals[mid]) / 2.0 if n % 2 == 0 else vals[mid], 2
            )
    except Exception:
        pass

# ── active_gaps + p0_count from state.db ─────────────────────────────────────
active_gaps = 0
p0_count    = 0
if os.path.isfile(state_db):
    try:
        conn = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
        active_gaps = conn.execute(
            "SELECT COUNT(*) FROM gaps WHERE status = 'open'"
        ).fetchone()[0]
        p0_count = conn.execute(
            "SELECT COUNT(*) FROM gaps WHERE status = 'open' AND priority = 'P0'"
        ).fetchone()[0]
        conn.close()
    except Exception:
        pass

# ── assemble event ────────────────────────────────────────────────────────────
event = {
    "ts":               ts_str,
    "kind":             "fleet_metrics_snapshot",
    "ship_rate_24h":    ship_rate_24h,
    "waste_rate_24h":   waste_rate_24h,
    "cycle_time_p50_h": cycle_time_p50_h,
    "active_gaps":      active_gaps,
    "p0_count":         p0_count,
}
line = json.dumps(event, separators=(",", ":"))

# ── emit to ambient.jsonl ─────────────────────────────────────────────────────
if not dry_run:
    os.makedirs(os.path.dirname(ambient_path), exist_ok=True)
    try:
        with open(ambient_path, "a") as f:
            f.write(line + "\n")
    except OSError as e:
        print(f"warn: could not append to ambient.jsonl: {e}", file=sys.stderr)

# ── output ────────────────────────────────────────────────────────────────────
if want_json or dry_run:
    print(json.dumps(event, indent=2))
else:
    sr = f"{event['ship_rate_24h']:.1%}"
    wr = f"{event['waste_rate_24h']:.3f}"
    ct = f"{event['cycle_time_p50_h']:.2f}h"
    print(f"fleet metrics snapshot  ts={ts_str}  window={window_h}h")
    print(f"  ship_rate_24h    = {sr}")
    print(f"  waste_rate_24h   = {wr}")
    print(f"  cycle_time_p50_h = {ct}")
    print(f"  active_gaps      = {event['active_gaps']}")
    print(f"  p0_count         = {event['p0_count']}")
PYEOF
