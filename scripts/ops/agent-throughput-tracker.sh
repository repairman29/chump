#!/usr/bin/env bash
# scripts/ops/agent-throughput-tracker.sh — FLEET-044
#
# Aggregates session_end events from ambient.jsonl by agent_id (session_id proxy).
# Writes daily summary to .chump/metrics/agent-throughput-YYYY-MM-DD.json
#
# Fields per agent: agent_id, ships, fails, P50_minutes_per_ship, top_fail_modes
#
# Usage:
#   agent-throughput-tracker.sh                # today's date
#   agent-throughput-tracker.sh --date 2026-05-11
#   agent-throughput-tracker.sh --json         # print result to stdout
#   CHUMP_AMBIENT_LOG=/path/to/ambient.jsonl agent-throughput-tracker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
TODAY="$(date +%Y-%m-%d)"
TARGET_DATE="$TODAY"
WANT_JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --date) TARGET_DATE="$2"; shift 2 ;;
        --json) WANT_JSON=1; shift ;;
        *) shift ;;
    esac
done

METRICS_DIR="$REPO_ROOT/.chump/metrics"
mkdir -p "$METRICS_DIR"
OUT_FILE="$METRICS_DIR/agent-throughput-${TARGET_DATE}.json"

python3 - "$AMBIENT" "$TARGET_DATE" "$OUT_FILE" <<'PYEOF'
import sys, json
from collections import defaultdict, Counter

ambient_path = sys.argv[1]
target_date = sys.argv[2]
out_file = sys.argv[3]

# agent_id -> {ships, fails, ship_elapsed_secs, fail_modes}
agents = defaultdict(lambda: {"ships": 0, "fails": 0, "ship_elapsed": [], "fail_modes": []})

try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line or '"kind":"session_end"' not in line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = d.get("ts", "")
            if not ts.startswith(target_date):
                continue
            # Use session_id as agent identity (format: claim-GAPID-PID-TS)
            agent_id = d.get("agent_id") or d.get("session_id") or "unknown"
            outcome = d.get("outcome", "unknown")
            elapsed = d.get("elapsed_seconds")
            if outcome == "shipped":
                agents[agent_id]["ships"] += 1
                if elapsed is not None:
                    agents[agent_id]["ship_elapsed"].append(int(elapsed))
            else:
                agents[agent_id]["fails"] += 1
                agents[agent_id]["fail_modes"].append(outcome)
except FileNotFoundError:
    pass

def p50(vals):
    if not vals:
        return None
    s = sorted(vals)
    mid = len(s) // 2
    return (s[mid - 1] + s[mid]) / 2.0 if len(s) % 2 == 0 else float(s[mid])

result = []
for agent_id in sorted(agents):
    data = agents[agent_id]
    p50_secs = p50(data["ship_elapsed"])
    p50_min = round(p50_secs / 60.0, 1) if p50_secs is not None else None
    top_fail = [m for m, _ in Counter(data["fail_modes"]).most_common(3)]
    result.append({
        "agent_id": agent_id,
        "ships": data["ships"],
        "fails": data["fails"],
        "P50_minutes_per_ship": p50_min,
        "top_fail_modes": top_fail,
    })

out = {
    "date": target_date,
    "agents": result,
    "total_ships": sum(a["ships"] for a in result),
    "total_fails": sum(a["fails"] for a in result),
}

with open(out_file, "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")

print(f"Wrote {out_file} ({len(result)} agents, {out['total_ships']} ships, {out['total_fails']} fails)")
PYEOF

if [[ "$WANT_JSON" -eq 1 ]]; then
    cat "$OUT_FILE"
fi
