#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Checks per-pillar pickable gap counts and emits alerts when imbalanced.
# Bash 3.2 compatible (macOS /bin/bash) — no declare -A/-n/mapfile/readarray.
#
# AC:
# 1. Reads state.db via 'chump gap list --status open --json'
# 2. Counts pickable (P0|P1, xs|s|m, no TODO ACs, no blocked deps) per pillar
# 3. Emits kind=pillar_balance_alert when pillar count < 2 (configurable)
# 4. Emits kind=pillar_balance_overweight when pillar count > 50% of total
# 5. Exits non-zero if any alert fired
# 6. Called by 'chump gap audit-priorities' (INFRA-902 AC5)
#
# Usage:
#   scripts/ops/pillar-balance-check.sh [--dry-run]
#
# Environment:
#   CHUMP_BIN                         — path to chump binary (default: auto-detect)
#   CHUMP_AMBIENT_OVERRIDE            — override ambient.jsonl path
#   CHUMP_PILLAR_BALANCE_FLOOR        — minimum pickable per pillar (default: 2)
#   CHUMP_PILLAR_BALANCE_OVERWEIGHT_PCT — overweight threshold % (default: 50)
#   CHUMP_PILLAR_BALANCE_DISABLED     — set to 1 to bypass all checks

set -uo pipefail

if [ "${CHUMP_PILLAR_BALANCE_DISABLED:-0}" = "1" ]; then
    echo "[pillar-balance-check] CHUMP_PILLAR_BALANCE_DISABLED=1 — bypass"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Binary discovery (honors shared target-dir per INFRA-481) ─────────────────
if [ -z "${CHUMP_BIN:-}" ]; then
    if command -v cargo >/dev/null 2>&1; then
        _target_dir=$(cargo metadata --no-deps \
            --manifest-path "$REPO_ROOT/Cargo.toml" \
            --format-version 1 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('target_directory',''))" \
            2>/dev/null || true)
    else
        _target_dir=""
    fi
    if [ -x "${_target_dir:-}/debug/chump" ]; then
        CHUMP_BIN="${_target_dir}/debug/chump"
    elif [ -x "$REPO_ROOT/target/debug/chump" ]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "[pillar-balance-check] ERROR: chump binary not found — set CHUMP_BIN" >&2
        exit 2
    fi
fi

AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FLOOR="${CHUMP_PILLAR_BALANCE_FLOOR:-2}"
OVERWEIGHT_PCT="${CHUMP_PILLAR_BALANCE_OVERWEIGHT_PCT:-50}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

emit_event() {
    local kind="$1" fields="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[pillar-balance-check] DRY-RUN: $kind — {$fields}"
        return
    fi
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","session":"pillar-balance-check","kind":"%s",%s}\n' \
        "$(ts)" "$kind" "$fields" >> "$AMBIENT" 2>/dev/null || true
}

# ── Fetch open gaps as JSON ────────────────────────────────────────────────────
GAP_JSON=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null) || {
    echo "[pillar-balance-check] ERROR: chump gap list --status open --json failed" >&2
    exit 2
}

# ── Parse via python3 (Bash-3.2-compatible — no declare -A) ───────────────────
TMP_JSON=$(mktemp)
trap 'rm -f "$TMP_JSON"' EXIT
printf '%s' "$GAP_JSON" > "$TMP_JSON"

COUNTS=$(python3 - "$TMP_JSON" "$FLOOR" "$OVERWEIGHT_PCT" <<'PYEOF'
import sys, json

json_path = sys.argv[1]
floor = int(sys.argv[2])
overweight_pct = int(sys.argv[3])

with open(json_path) as f:
    try:
        gaps = json.load(f)
    except Exception as e:
        sys.stderr.write("parse error: {}\n".format(e))
        sys.exit(2)

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]

def is_pickable(g):
    priority = g.get("priority", "")
    effort = g.get("effort", "")
    ac = str(g.get("acceptance_criteria", ""))
    depends_on = g.get("depends_on") or "[]"

    if priority not in ("P0", "P1"):
        return False
    if effort not in ("xs", "s", "m"):
        return False
    # No TODO ACs
    if "TODO" in ac:
        return False
    # No blocked deps (non-empty array)
    try:
        deps = json.loads(depends_on)
        if deps:
            return False
    except Exception:
        if str(depends_on).strip() not in ("[]", ""):
            return False
    return True

def get_pillar(title):
    for p in PILLARS:
        if title.startswith(p + ":") or title.startswith(p + " "):
            return p
    return "OTHER"

counts = {"EFFECTIVE": 0, "CREDIBLE": 0, "RESILIENT": 0, "ZERO-WASTE": 0}
total = 0

for g in gaps:
    if not is_pickable(g):
        continue
    pillar = get_pillar(g.get("title", ""))
    if pillar in counts:
        counts[pillar] += 1
    total += 1

for p in PILLARS:
    print("{}={}".format(p, counts[p]))
print("TOTAL={}".format(total))
PYEOF
)

# Extract counts (Bash 3.2 compatible — no arrays)
_effective=$(printf '%s\n' "$COUNTS" | grep "^EFFECTIVE=" | cut -d= -f2)
_credible=$(printf '%s\n' "$COUNTS" | grep "^CREDIBLE=" | cut -d= -f2)
_resilient=$(printf '%s\n' "$COUNTS" | grep "^RESILIENT=" | cut -d= -f2)
_zerowaste=$(printf '%s\n' "$COUNTS" | grep "^ZERO-WASTE=" | cut -d= -f2)
_total=$(printf '%s\n' "$COUNTS" | grep "^TOTAL=" | cut -d= -f2)

_effective="${_effective:-0}"
_credible="${_credible:-0}"
_resilient="${_resilient:-0}"
_zerowaste="${_zerowaste:-0}"
_total="${_total:-0}"

echo "[pillar-balance-check] Pickable gaps (P0/P1, xs/s/m, no-TODO-AC, no-deps):"
echo "  EFFECTIVE=$_effective  CREDIBLE=$_credible  RESILIENT=$_resilient  ZERO-WASTE=$_zerowaste  TOTAL=$_total"

ALERTS_FIRED=0

# ── Floor check: emit pillar_balance_alert when count < FLOOR ─────────────────
# ANCHOR: kind=pillar_balance_alert emitter=scripts/ops/pillar-balance-check.sh
for _pillar_count in "EFFECTIVE:$_effective" "CREDIBLE:$_credible" "RESILIENT:$_resilient" "ZERO-WASTE:$_zerowaste"; do
    _p="${_pillar_count%%:*}"
    _c="${_pillar_count##*:}"
    if [ "$_c" -lt "$FLOOR" ]; then
        echo "  ALERT: $_p has only $_c pickable gaps (floor=$FLOOR)"
        emit_event "pillar_balance_alert" \
            "\"pillar\":\"$_p\",\"count\":$_c,\"floor\":$FLOOR"
        ALERTS_FIRED=$((ALERTS_FIRED + 1))
    fi
done

# ── Overweight check: emit pillar_balance_overweight when > OVERWEIGHT_PCT% ───
# ANCHOR: kind=pillar_balance_overweight emitter=scripts/ops/pillar-balance-check.sh
if [ "$_total" -gt 0 ]; then
    for _pillar_count in "EFFECTIVE:$_effective" "CREDIBLE:$_credible" "RESILIENT:$_resilient" "ZERO-WASTE:$_zerowaste"; do
        _p="${_pillar_count%%:*}"
        _c="${_pillar_count##*:}"
        _pct=$(( (_c * 100) / _total ))
        if [ "$_pct" -gt "$OVERWEIGHT_PCT" ]; then
            echo "  ALERT: $_p is overweight — ${_pct}% of total pickable (threshold=${OVERWEIGHT_PCT}%)"
            emit_event "pillar_balance_overweight" \
                "\"pillar\":\"$_p\",\"count\":$_c,\"pct\":$_pct,\"total\":$_total,\"threshold\":$OVERWEIGHT_PCT"
            ALERTS_FIRED=$((ALERTS_FIRED + 1))
        fi
    done
fi

if [ "$ALERTS_FIRED" -gt 0 ]; then
    echo "[pillar-balance-check] $ALERTS_FIRED alert(s) fired — exit 1"
    exit 1
fi

echo "[pillar-balance-check] All pillars balanced (floor=$FLOOR, overweight=${OVERWEIGHT_PCT}%). OK."
exit 0
