#!/bin/bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Bash-3.2 compatible pillar-balance analyzer.
# Reads open gaps via 'chump gap list --status open --json', counts
# pickable gaps (P0|P1, xs|s|m effort, pillar-tagged title) per pillar,
# then emits ambient events and exits non-zero when thresholds breach.
#
# Alert kinds:
#   pillar_balance_alert       — pillar count < floor (default 2)
#   pillar_balance_overweight  — pillar count > 50% of total pickable
#
# Env overrides:
#   CHUMP_BIN                override chump binary path
#   CHUMP_REPO               repo root override (chump uses this internally)
#   CHUMP_AMBIENT_OVERRIDE   override ambient.jsonl path
#   CHUMP_PILLAR_FLOOR       floor count threshold (default: 2)
#   CHUMP_PILLAR_OVERWEIGHT  overweight fraction threshold as float (default: 0.50)
#   CHUMP_PILLAR_DRY_RUN     set to 1 to skip ambient writes

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FLOOR="${CHUMP_PILLAR_FLOOR:-2}"
OVERWEIGHT="${CHUMP_PILLAR_OVERWEIGHT:-0.50}"
DRY_RUN="${CHUMP_PILLAR_DRY_RUN:-0}"
CHUMP_BIN="${CHUMP_BIN:-chump}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

emit() {
    local payload="$1"
    if [ "$DRY_RUN" = "0" ]; then
        mkdir -p "$(dirname "$AMBIENT")"
        printf '%s\n' "$payload" >> "$AMBIENT" 2>/dev/null || true
    fi
    printf '%s\n' "$payload"
}

# Get open gaps as JSON
GAPS_JSON=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null) || {
    echo "[pillar-balance-check] WARN: could not run '$CHUMP_BIN gap list' — skipping" >&2
    exit 0
}

# Use python3 via env variable to parse JSON and count pickable gaps per pillar.
# Pickable = priority P0|P1, effort xs|s|m, pillar-tagged title, no TODO ACs, no deps.
# Output: one line per pillar "PILLAR <name> <count>", then "TOTAL <n>"
PILLARS_JSON="$GAPS_JSON"
COUNTS=$(PILLARS_JSON="$PILLARS_JSON" FLOOR="$FLOOR" OVERWEIGHT="$OVERWEIGHT" python3 - <<'PYEOF'
import sys, json, os

raw = os.environ.get("PILLARS_JSON", "[]")
try:
    gaps = json.loads(raw)
except Exception:
    gaps = []

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]
PICKABLE_PRIORITIES = {"P0", "P1"}
PICKABLE_EFFORTS = {"xs", "s", "m"}

def title_pillar(title):
    up = title.upper()
    for p in PILLARS:
        # match "PILLAR: " or "PILLAR " or "PILLAR-"
        alt = p.replace("-", "_")
        if (up.startswith(p + ":") or up.startswith(p + " ") or up.startswith(p + "-") or
                up.startswith(alt + ":") or up.startswith(alt + " ")):
            return p
    return None

counts = {p: 0 for p in PILLARS}
total = 0

for g in gaps:
    if not isinstance(g, dict):
        continue
    priority = g.get("priority", "")
    effort = g.get("effort", "")
    title = g.get("title", "")
    depends_on = g.get("depends_on", "[]")
    ac = g.get("acceptance_criteria", "")

    if priority not in PICKABLE_PRIORITIES:
        continue
    if effort not in PICKABLE_EFFORTS:
        continue

    # Skip gaps with TODO acceptance criteria
    if "TODO" in str(ac).upper():
        continue

    # Skip gaps with non-empty depends_on (blocked)
    dep_str = str(depends_on).strip()
    if dep_str and dep_str not in ("[]", "null", ""):
        try:
            deps = json.loads(dep_str)
            if isinstance(deps, list) and len(deps) > 0:
                continue
        except Exception:
            continue  # non-parseable deps = blocked

    pillar = title_pillar(title)
    if pillar:
        counts[pillar] += 1
        total += 1

for p in PILLARS:
    print("PILLAR {} {}".format(p, counts[p]))
print("TOTAL {}".format(total))
PYEOF
) || {
    echo "[pillar-balance-check] WARN: python3 failed — skipping" >&2
    exit 0
}

# Parse counts — Bash 3.2 compatible (no declare -A)
eff_count=0
cre_count=0
res_count=0
zw_count=0
total_pickable=0

while IFS=" " read -r label pillar_or_total value; do
    case "$label $pillar_or_total" in
        "PILLAR EFFECTIVE")  eff_count=$((${value:-0} + 0)) ;;
        "PILLAR CREDIBLE")   cre_count=$((${value:-0} + 0)) ;;
        "PILLAR RESILIENT")  res_count=$((${value:-0} + 0)) ;;
        "PILLAR ZERO-WASTE") zw_count=$((${value:-0} + 0)) ;;
        "TOTAL "*)
            # label=TOTAL, pillar_or_total=<number> when only 2 words
            total_pickable=$((${pillar_or_total:-0} + 0))
            ;;
    esac
done <<< "$COUNTS"

echo "[pillar-balance-check] pickable: EFFECTIVE=$eff_count CREDIBLE=$cre_count RESILIENT=$res_count ZERO-WASTE=$zw_count total=$total_pickable"

ALERTS_FIRED=0

# Convert OVERWEIGHT float to integer percentage for Bash arithmetic (0.50 -> 50)
OW_PCT=$(python3 -c "import sys; print(int(float('$OVERWEIGHT') * 100))" 2>/dev/null || echo 50)

# Check floor + overweight for a single pillar
# Args: pillar_name count total_pickable floor_val ow_pct
check_pillar() {
    local pillar="$1"
    local count="$2"
    local total="$3"
    local floor_val="$4"
    local ow_pct="$5"

    if [ "$count" -lt "$floor_val" ]; then
        local payload
        payload="$(printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":%d}' \
            "$(ts)" "$pillar" "$count" "$floor_val")"
        emit "$payload"
        ALERTS_FIRED=$((ALERTS_FIRED + 1))
    fi

    if [ "$total" -gt 0 ]; then
        local pct=$(( count * 100 / total ))
        if [ "$pct" -gt "$ow_pct" ]; then
            local payload
            payload="$(printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}' \
                "$(ts)" "$pillar" "$count" "$pct")"
            emit "$payload"
            ALERTS_FIRED=$((ALERTS_FIRED + 1))
        fi
    fi
}

check_pillar "EFFECTIVE"  "$eff_count" "$total_pickable" "$FLOOR" "$OW_PCT"
check_pillar "CREDIBLE"   "$cre_count" "$total_pickable" "$FLOOR" "$OW_PCT"
check_pillar "RESILIENT"  "$res_count" "$total_pickable" "$FLOOR" "$OW_PCT"
check_pillar "ZERO-WASTE" "$zw_count"  "$total_pickable" "$FLOOR" "$OW_PCT"

if [ "$ALERTS_FIRED" -gt 0 ]; then
    echo "[pillar-balance-check] $ALERTS_FIRED alert(s) fired" >&2
    exit 1
fi

echo "[pillar-balance-check] all pillars within bounds"
exit 0
