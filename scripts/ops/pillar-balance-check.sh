#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance analyzer: reads open gaps via 'chump gap list --json --status open',
# counts pickable (P0|P1 xs|s|m, no vague AC, no open blocked deps) per pillar
# (EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE), and fires ambient alerts when
# any pillar is under-stocked (< 2) or overweight (> 50% of the pickable pool).
#
# NOTE: Bash 3.2 compatible (no declare -A / declare -n / mapfile / readarray).
#
# Emits to ambient.jsonl:
#   kind=pillar_balance_alert      {pillar, count, floor=2}   when count < 2
#   kind=pillar_balance_overweight {pillar, count, pct}       when count > 50%
#
# Exit:
#   0 — no alerts
#   1 — at least one alert fired
#   2 — usage/config error
#
# Env overrides:
#   CHUMP_BIN                    path to chump binary (default: PATH lookup)
#   CHUMP_REPO                   repo root used to locate state.db
#   CHUMP_AMBIENT_LOG            path to ambient.jsonl
#                                (default: <repo-root>/.chump-locks/ambient.jsonl)
#   CHUMP_PILLAR_FLOOR           alert threshold (default: 2)
#   CHUMP_PILLAR_BALANCE_CHECK=0 bypass: silently exits 0
#   CHUMP_PILLAR_BALANCE_DRY_RUN=1
#                                compute + print but skip ambient write

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${REPO_ROOT}/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
CHUMP_BIN="${CHUMP_BIN:-chump}"
FLOOR="${CHUMP_PILLAR_FLOOR:-2}"
DRY_RUN="${CHUMP_PILLAR_BALANCE_DRY_RUN:-0}"

# Bypass
if [[ "${CHUMP_PILLAR_BALANCE_CHECK:-1}" == "0" ]]; then
    exit 0
fi

# Pass CHUMP_REPO through to chump if set
if [[ -n "${CHUMP_REPO:-}" ]]; then
    export CHUMP_REPO
fi

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Fetch open gaps as JSON ───────────────────────────────────────────────────
GAP_JSON=$("$CHUMP_BIN" gap list --json --status open 2>/dev/null) || {
    echo "pillar-balance-check: 'chump gap list' failed" >&2
    exit 2
}

# ── Compute per-pillar counts via python3 (Bash 3.2 safe) ────────────────────
COUNTS=$(echo "$GAP_JSON" | python3 - << 'PYEOF'
import sys, json

try:
    data = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("pillar-balance-check: JSON parse error: %s\n" % e)
    sys.exit(2)

if not isinstance(data, list):
    # Wrapped format (e.g. {"gaps": [...]})
    data = data.get("gaps", [])

pillars = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]
counts = dict((p, 0) for p in pillars)
total = 0

open_ids = set(g["id"] for g in data if g.get("status") == "open")

for g in data:
    if g.get("status") != "open":
        continue
    if g.get("priority") not in ("P0", "P1"):
        continue
    if g.get("effort") not in ("xs", "s", "m"):
        continue

    # Vague AC check
    ac = (g.get("acceptance_criteria") or "").strip()
    if not ac:
        continue

    # Open blocked deps check
    deps_raw = g.get("depends_on", "[]")
    try:
        if isinstance(deps_raw, str):
            deps = json.loads(deps_raw)
        else:
            deps = deps_raw or []
    except Exception:
        deps = []
    if isinstance(deps, list) and any(str(d) in open_ids for d in deps):
        continue

    title_up = g.get("title", "").upper()
    for p in pillars:
        if p in title_up:
            counts[p] += 1
            total += 1
            break

for p in pillars:
    print("%s %d" % (p, counts[p]))
print("TOTAL %d" % total)
PYEOF
) || exit 2

# ── Parse individual counts from python3 output (no declare -A) ──────────────
EFFECTIVE_COUNT=$(echo "$COUNTS" | awk '$1=="EFFECTIVE"{print $2}')
CREDIBLE_COUNT=$(echo  "$COUNTS" | awk '$1=="CREDIBLE"{print $2}')
RESILIENT_COUNT=$(echo "$COUNTS" | awk '$1=="RESILIENT"{print $2}')
ZEROWASTE_COUNT=$(echo "$COUNTS" | awk '$1=="ZERO-WASTE"{print $2}')
TOTAL_COUNT=$(echo     "$COUNTS" | awk '$1=="TOTAL"{print $2}')

EFFECTIVE_COUNT="${EFFECTIVE_COUNT:-0}"
CREDIBLE_COUNT="${CREDIBLE_COUNT:-0}"
RESILIENT_COUNT="${RESILIENT_COUNT:-0}"
ZEROWASTE_COUNT="${ZEROWASTE_COUNT:-0}"
TOTAL_COUNT="${TOTAL_COUNT:-0}"

# ── Print summary ─────────────────────────────────────────────────────────────
echo "=== pillar balance ==="
echo "Pickable pool: ${TOTAL_COUNT}"
echo "  EFFECTIVE  : ${EFFECTIVE_COUNT}"
echo "  CREDIBLE   : ${CREDIBLE_COUNT}"
echo "  RESILIENT  : ${RESILIENT_COUNT}"
echo "  ZERO-WASTE : ${ZEROWASTE_COUNT}"
echo "(floor=${FLOOR}, overweight threshold=50%)"

# ── Alert and emit logic ──────────────────────────────────────────────────────
ALERTS=0
TS="$(now_ts)"

emit_event() {
    local json_line="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        return
    fi
    mkdir -p "$(dirname "$AMBIENT_LOG")"
    echo "$json_line" >> "$AMBIENT_LOG"
}

check_pillar() {
    local name="$1"
    local count="$2"
    local total="$3"
    local floor="$4"

    # Under-stocked check
    if [[ "$count" -lt "$floor" ]]; then
        echo "ALERT: ${name} has ${count} pickable gap(s) (floor=${floor})"
        emit_event "{\"ts\":\"${TS}\",\"kind\":\"pillar_balance_alert\",\"pillar\":\"${name}\",\"count\":${count},\"floor\":${floor}}"
        ALERTS=$((ALERTS + 1))
    fi

    # Overweight check: count > 50% of total (count * 2 > total)
    if [[ "$total" -gt 0 ]] && [[ $((count * 2)) -gt "$total" ]]; then
        local pct=$(( count * 100 / total ))
        echo "ALERT: ${name} is overweight: ${count}/${total} (${pct}%)"
        emit_event "{\"ts\":\"${TS}\",\"kind\":\"pillar_balance_overweight\",\"pillar\":\"${name}\",\"count\":${count},\"pct\":${pct}}"
        ALERTS=$((ALERTS + 1))
    fi
}

check_pillar "EFFECTIVE"  "$EFFECTIVE_COUNT"  "$TOTAL_COUNT" "$FLOOR"
check_pillar "CREDIBLE"   "$CREDIBLE_COUNT"   "$TOTAL_COUNT" "$FLOOR"
check_pillar "RESILIENT"  "$RESILIENT_COUNT"  "$TOTAL_COUNT" "$FLOOR"
check_pillar "ZERO-WASTE" "$ZEROWASTE_COUNT"  "$TOTAL_COUNT" "$FLOOR"

if [[ "$ALERTS" -eq 0 ]]; then
    echo "OK: all pillars balanced"
    exit 0
else
    exit 1
fi
