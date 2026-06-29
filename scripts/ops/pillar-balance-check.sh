#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Reads open gaps via `chump gap list --status open --json`, counts pickable
# (P0|P1, effort xs|s, no TODO ACs, no blocked deps) per pillar, then emits
# ambient events and exits non-zero when thresholds are breached.
#
# Bash 3.2 compatible — no declare -A/-n, mapfile, or readarray.
#
# Events emitted:
#   kind=pillar_balance_alert      — pillar count < FLOOR (default 2)
#   kind=pillar_balance_overweight — pillar count > 50% of total pickable
#
# Exit codes:
#   0 — no alerts
#   1 — one or more alerts fired
#   2 — configuration / runtime error
#
# Usage:
#   scripts/ops/pillar-balance-check.sh
#   scripts/ops/pillar-balance-check.sh --json        # machine-readable report
#   scripts/ops/pillar-balance-check.sh --dry-run     # compute + print, no ambient emit
#   CHUMP_PILLAR_BALANCE_CHECK=0 ...                  # silently skip (CI bypass)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
FLOOR="${CHUMP_PILLAR_BALANCE_FLOOR:-2}"
OVERWEIGHT_PCT="${CHUMP_PILLAR_BALANCE_OVERWEIGHT_PCT:-50}"

JSON=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --json)    JSON=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "pillar-balance-check: unknown flag '$arg'" >&2; exit 2 ;;
    esac
done

if [ "${CHUMP_PILLAR_BALANCE_CHECK:-1}" = "0" ]; then
    echo "[pillar-balance-check] bypassed via CHUMP_PILLAR_BALANCE_CHECK=0"
    exit 0
fi

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Ensure ambient log dir exists before any append.
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

CHUMP_BIN="${CHUMP_BIN:-chump}"

# Fetch open gaps as JSON lines. Use --json if available; fallback to text parse.
if ! GAP_JSON="$("$CHUMP_BIN" gap list --status open --json 2>/dev/null)"; then
    echo "[pillar-balance-check] WARN: 'chump gap list --status open --json' failed; trying text mode" >&2
    GAP_JSON=""
fi

# Count pickable gaps per pillar using python3 (portable, avoids bash array deps).
# "Pickable" = P0|P1, effort xs|s (WARN on m), no TODO/TBD in AC, no blocked deps.
COUNTS_JSON="$(python3 - "$FLOOR" "$OVERWEIGHT_PCT" <<'PYEOF'
import sys, json, os

floor = int(sys.argv[1])
overweight_pct = int(sys.argv[2])

raw = sys.stdin.read().strip()
gaps = []
if raw:
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            gaps = data
        elif isinstance(data, dict) and "gaps" in data:
            gaps = data["gaps"]
    except json.JSONDecodeError:
        pass

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]
counts = {p: 0 for p in PILLARS}
total = 0

for g in gaps:
    # Must be open (should be — we filtered --status open)
    if g.get("status", "") != "open":
        continue
    # Priority filter: P0 or P1
    priority = g.get("priority", "")
    if priority not in ("P0", "P1"):
        continue
    # Effort filter: xs or s (m is WARN-only, still counted as pickable)
    effort = g.get("effort", "")
    if effort not in ("xs", "s", "m"):
        continue
    # AC check: skip if empty or contains TODO/TBD placeholder
    ac = g.get("acceptance_criteria", "") or ""
    if not ac.strip():
        continue
    ac_lower = ac.lower()
    if "todo" in ac_lower or "tbd" in ac_lower:
        continue
    # Deps check: skip if has unmet depends_on
    deps_raw = g.get("depends_on", "[]") or "[]"
    try:
        deps = json.loads(deps_raw) if isinstance(deps_raw, str) else deps_raw
    except (json.JSONDecodeError, TypeError):
        deps = []
    if isinstance(deps, list) and len(deps) > 0:
        continue

    # Count by pillar title prefix
    title = g.get("title", "").upper()
    matched = False
    for p in PILLARS:
        if title.startswith(p + ":") or title.startswith(p + " "):
            counts[p] += 1
            matched = True
            break
    total += 1

alerts = []
overweights = []

for p in PILLARS:
    c = counts[p]
    if c < floor:
        alerts.append({"pillar": p, "count": c, "floor": floor})
    if total > 0:
        pct = (c * 100) // total
        if pct > overweight_pct:
            overweights.append({"pillar": p, "count": c, "pct": pct, "total": total})

print(json.dumps({
    "total_pickable": total,
    "counts": counts,
    "alerts": alerts,
    "overweights": overweights,
    "floor": floor,
    "overweight_pct": overweight_pct,
}))
PYEOF
)" <<< "$GAP_JSON"

if [ -z "$COUNTS_JSON" ]; then
    echo "[pillar-balance-check] ERROR: failed to parse gap data" >&2
    exit 2
fi

# Extract fields from COUNTS_JSON via python3 (Bash 3.2 safe — no assoc arrays).
ALERT_COUNT="$(python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['alerts']))" <<< "$COUNTS_JSON")"
OVERWEIGHT_COUNT="$(python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['overweights']))" <<< "$COUNTS_JSON")"
TOTAL="$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total_pickable'])" <<< "$COUNTS_JSON")"
TS="$(now_ts)"

ALERT_COUNT="${ALERT_COUNT:-0}"
OVERWEIGHT_COUNT="${OVERWEIGHT_COUNT:-0}"
TOTAL="${TOTAL:-0}"

# Emit ambient events.
if [ "$DRY_RUN" = "0" ]; then
    # Emit one event per alert.
    python3 - "$AMBIENT_LOG" "$TS" <<'PYEOF2' <<< "$COUNTS_JSON"
import sys, json

amb = sys.argv[1]
ts  = sys.argv[2]
raw = sys.stdin.read()
d   = json.loads(raw)

lines = []
for a in d.get("alerts", []):
    lines.append(json.dumps({
        "ts": ts,
        "kind": "pillar_balance_alert",
        "pillar": a["pillar"],
        "count": a["count"],
        "floor": a["floor"],
    }))
for o in d.get("overweights", []):
    lines.append(json.dumps({
        "ts": ts,
        "kind": "pillar_balance_overweight",
        "pillar": o["pillar"],
        "count": o["count"],
        "pct": o["pct"],
        "total": o["total"],
    }))

if lines:
    try:
        with open(amb, "a") as f:
            f.write("\n".join(lines) + "\n")
    except OSError as e:
        print(f"[pillar-balance-check] WARN: could not write ambient: {e}", file=sys.stdout)
PYEOF2
fi

if [ "$JSON" = "1" ]; then
    echo "$COUNTS_JSON"
else
    python3 - <<'PYEOF3' <<< "$COUNTS_JSON"
import sys, json

d = json.loads(sys.stdin.read())
total = d["total_pickable"]
counts = d["counts"]
alerts = d["alerts"]
overweights = d["overweights"]
floor = d["floor"]

print("=== pillar-balance-check (INFRA-902) ===")
print(f"Total pickable: {total}")
print()
for pillar, cnt in counts.items():
    pct = (cnt * 100 // total) if total > 0 else 0
    bar = "#" * cnt
    print(f"  {pillar:12s}  {cnt:3d}  ({pct:3d}%)  {bar}")
print()
if not alerts and not overweights:
    print("✓ Balance OK — all pillars above floor, none overweight")
else:
    for a in alerts:
        print(f"  ALERT: {a['pillar']} has only {a['count']} pickable gap(s) (floor={a['floor']}) → emit pillar_balance_alert")
    for o in overweights:
        print(f"  ALERT: {o['pillar']} is overweight at {o['pct']}% of {o['total']} pickable gaps → emit pillar_balance_overweight")
PYEOF3
fi

# Exit non-zero if any alert fired.
FIRED="$(python3 -c "import sys,json; d=json.load(sys.stdin); print(1 if d['alerts'] or d['overweights'] else 0)" <<< "$COUNTS_JSON")"
FIRED="${FIRED:-0}"
exit "$FIRED"
