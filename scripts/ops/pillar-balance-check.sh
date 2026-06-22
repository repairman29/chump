#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance analyzer + ambient alerter.
#
# Reads open gaps via `chump gap list --status open --json`, counts pickable
# (P0|P1, effort xs|s|m, non-empty AC, no open deps) per pillar, then:
#   - Emits kind=pillar_balance_alert when any pillar count < 2 (floor)
#   - Emits kind=pillar_balance_overweight when any pillar > 50% of total
#   - Exits non-zero if any alert was fired
#
# Called by: chump gap audit-priorities (INFRA-902 AC5)
# Bash 3.2 compatible — no declare -A / declare -n / mapfile / readarray.
#
# Usage:
#   bash scripts/ops/pillar-balance-check.sh [--json]
#
# Env:
#   CHUMP_BIN            path to chump binary (default: auto-detect)
#   CHUMP_AMBIENT_LOG    path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   CHUMP_PILLAR_BALANCE_FLOOR  minimum pickable per pillar (default: 2)
#   CHUMP_PILLAR_BALANCE_CHECK_DISABLE  set to 1 to skip all checks (exit 0)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Config ────────────────────────────────────────────────────────────────────
FLOOR="${CHUMP_PILLAR_BALANCE_FLOOR:-2}"
EMIT_JSON=0
for _arg in "$@"; do
    [ "$_arg" = "--json" ] && EMIT_JSON=1
done

# Disable escape hatch
if [ "${CHUMP_PILLAR_BALANCE_CHECK_DISABLE:-0}" = "1" ]; then
    [ "$EMIT_JSON" = "1" ] && printf '{"disabled":true,"alerts":[]}\n'
    exit 0
fi

# ── Locate chump binary ───────────────────────────────────────────────────────
if [ -n "${CHUMP_BIN:-}" ] && [ -x "$CHUMP_BIN" ]; then
    BIN="$CHUMP_BIN"
elif [ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]; then
    BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
else
    # Try shared target-dir (INFRA-481) or parent repo
    PARENT_TARGET="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    if [ -x "$PARENT_TARGET" ]; then
        BIN="$PARENT_TARGET"
    else
        echo "FATAL: chump binary not found — set CHUMP_BIN or build with cargo" >&2
        exit 2
    fi
fi

# ── Ambient log path ──────────────────────────────────────────────────────────
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# ── Fetch open gaps as JSON ───────────────────────────────────────────────────
GAPS_JSON=$("$BIN" gap list --status open --json 2>/dev/null) || {
    echo "WARN: chump gap list failed — skipping pillar-balance-check" >&2
    exit 0
}

# ── Compute pillar counts via python3 (Bash 3.2 compat — no jq/declare -A) ──
# Pickable: P0|P1, effort xs|s|m, AC non-empty and non-TODO, depends_on empty/[]
#
# Outputs: total eff cre res zw
# Where: eff=EFFECTIVE cre=CREDIBLE res=RESILIENT zw=ZERO-WASTE
COUNTS=$(python3 - "$GAPS_JSON" <<'PYEOF'
import sys, json

gaps_json = sys.argv[1]
try:
    gaps = json.loads(gaps_json)
except Exception:
    gaps = []

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]
counts = {p: 0 for p in PILLARS}
total = 0

for g in gaps:
    if g.get("status") != "open":
        continue
    if g.get("priority") not in ("P0", "P1"):
        continue
    if g.get("effort") not in ("xs", "s", "m"):
        continue
    # AC must be non-empty and not TODO placeholder
    ac = g.get("acceptance_criteria", "")
    if isinstance(ac, list):
        ac_text = " ".join(str(a) for a in ac)
    else:
        ac_text = str(ac)
    if not ac_text.strip() or ac_text.strip() == "TODO" or ac_text.strip() == "[]":
        continue
    # depends_on must be empty or []
    dep = g.get("depends_on", "[]")
    if isinstance(dep, list):
        if any(dep):
            continue
    else:
        dep_str = str(dep).strip()
        if dep_str and dep_str != "[]" and dep_str != "null":
            try:
                parsed = json.loads(dep_str)
                if isinstance(parsed, list) and any(parsed):
                    continue
            except Exception:
                # non-parseable => treat as blocked
                continue
    # Assign to pillar based on title prefix
    title_up = g.get("title", "").upper()
    assigned = False
    for p in PILLARS:
        if p in title_up:
            counts[p] += 1
            assigned = True
            break
    total += 1

# Output: total eff cre res zw
print(total, counts["EFFECTIVE"], counts["CREDIBLE"], counts["RESILIENT"], counts["ZERO-WASTE"])
PYEOF
) 2>/dev/null || COUNTS="0 0 0 0 0"

# Parse counts into plain variables (Bash 3.2 compat)
total_pickable=$(echo "$COUNTS" | awk '{print $1}')
count_EFFECTIVE=$(echo "$COUNTS" | awk '{print $2}')
count_CREDIBLE=$(echo "$COUNTS"  | awk '{print $3}')
count_RESILIENT=$(echo "$COUNTS" | awk '{print $4}')
count_ZEROASTE=$(echo "$COUNTS"  | awk '{print $5}')

# Validate numeric (default to 0 on failure)
total_pickable=${total_pickable:-0}
count_EFFECTIVE=${count_EFFECTIVE:-0}
count_CREDIBLE=${count_CREDIBLE:-0}
count_RESILIENT=${count_RESILIENT:-0}
count_ZEROASTE=${count_ZEROASTE:-0}

# ── Evaluate and emit alerts ──────────────────────────────────────────────────
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
ALERTS_FIRED=0

_emit_ambient() {
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '%s\n' "$1" >> "$AMBIENT" 2>/dev/null || true
}

_check_pillar() {
    local pillar="$1"
    local count="$2"
    # Floor check: alert if count < FLOOR
    if [ "$count" -lt "$FLOOR" ]; then
        ALERTS_FIRED=1
        local ev
        ev=$(printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":%d,"total_pickable":%d,"source":"pillar-balance-check"}' \
            "$TS" "$pillar" "$count" "$FLOOR" "$total_pickable")
        _emit_ambient "$ev"
        echo "ALERT: pillar_balance_alert pillar=$pillar count=$count floor=$FLOOR total_pickable=$total_pickable"
    fi
    # Overweight check: alert if count > 50% of total (i.e. count*2 > total)
    if [ "$total_pickable" -gt 0 ] && [ "$((count * 2))" -gt "$total_pickable" ]; then
        ALERTS_FIRED=1
        # Compute integer pct (count*100/total)
        local pct=$(( count * 100 / total_pickable ))
        local ev
        ev=$(printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d,"total_pickable":%d,"source":"pillar-balance-check"}' \
            "$TS" "$pillar" "$count" "$pct" "$total_pickable")
        _emit_ambient "$ev"
        echo "ALERT: pillar_balance_overweight pillar=$pillar count=$count pct=${pct}% total_pickable=$total_pickable"
    fi
}

_check_pillar "EFFECTIVE"  "$count_EFFECTIVE"
_check_pillar "CREDIBLE"   "$count_CREDIBLE"
_check_pillar "RESILIENT"  "$count_RESILIENT"
_check_pillar "ZERO-WASTE" "$count_ZEROASTE"

# ── Summary output ────────────────────────────────────────────────────────────
if [ "$EMIT_JSON" = "1" ]; then
    printf '{"total_pickable":%d,"pillars":{"EFFECTIVE":%d,"CREDIBLE":%d,"RESILIENT":%d,"ZERO-WASTE":%d},"floor":%d,"alerts_fired":%d}\n' \
        "$total_pickable" \
        "$count_EFFECTIVE" "$count_CREDIBLE" "$count_RESILIENT" "$count_ZEROASTE" \
        "$FLOOR" "$ALERTS_FIRED"
elif [ "$ALERTS_FIRED" = "0" ]; then
    printf '✓ Pillar balance OK: EFFECTIVE=%d CREDIBLE=%d RESILIENT=%d ZERO-WASTE=%d (of %d pickable)\n' \
        "$count_EFFECTIVE" "$count_CREDIBLE" "$count_RESILIENT" "$count_ZEROASTE" \
        "$total_pickable"
fi

[ "$ALERTS_FIRED" = "0" ] && exit 0 || exit 1
