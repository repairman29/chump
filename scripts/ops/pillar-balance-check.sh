#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Reads open gaps via 'chump gap list --status open --json', counts pickable
# gaps (P0|P1, xs|s|m effort, no TODO ACs, no blocked deps) per pillar.
#
# Emits kind=pillar_balance_alert when any pillar count < floor (default 2).
# Emits kind=pillar_balance_overweight when any pillar > overweight_pct% of pool.
# Exits non-zero if any alert fired.
#
# Bash 3.2 compatible — no declare -A/-n, no mapfile, no readarray.
#
# Usage:
#   scripts/ops/pillar-balance-check.sh [--dry-run] [--quiet]
#
# Env:
#   CHUMP_BIN              override chump binary path
#   CHUMP_AMBIENT_LOG      override ambient.jsonl path
#   PILLAR_BALANCE_FLOOR   min pickable per pillar (default: 2)
#   PILLAR_OVERWEIGHT_PCT  overweight threshold percentage (default: 50)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Resolve chump binary (honor cargo target_dir per INFRA-481) ───────────────
if [ -z "${CHUMP_BIN:-}" ]; then
    _td=""
    if _td_raw="$(cargo metadata --no-deps --format-version 1 \
            --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null)"; then
        _td="$(printf '%s' "$_td_raw" | \
            python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' \
            2>/dev/null || true)"
    fi
    if [ -x "${_td:-}/debug/chump" ]; then
        CHUMP_BIN="${_td}/debug/chump"
    elif [ -x "$REPO_ROOT/target/debug/chump" ]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    else
        echo "pillar-balance-check: chump binary not found" >&2
        exit 2
    fi
fi

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FLOOR="${PILLAR_BALANCE_FLOOR:-2}"
OVERWEIGHT_PCT="${PILLAR_OVERWEIGHT_PCT:-50}"
DRY_RUN=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --quiet)   QUIET=1;   shift ;;
        *) shift ;;
    esac
done

# ── Fetch open gaps as JSON ───────────────────────────────────────────────────
GAPS_JSON="$("$CHUMP_BIN" gap list --status open --json 2>/dev/null)" || {
    echo "pillar-balance-check: chump gap list failed" >&2
    exit 2
}

# ── Parse counts via python3 (Bash 3.2 compat: avoid assoc arrays) ────────────
COUNTS="$(printf '%s' "$GAPS_JSON" | python3 - "$FLOOR" "$OVERWEIGHT_PCT" <<'PYEOF'
import sys
import json

gaps = json.loads(sys.stdin.read())
floor = int(sys.argv[1])

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]

def is_pickable(g):
    if g.get("priority") not in ("P0", "P1"):
        return False
    if g.get("effort") not in ("xs", "s", "m"):
        return False
    ac = g.get("acceptance_criteria", "")
    if "TODO" in ac:
        return False
    dep = g.get("depends_on", "")
    if dep and dep not in ("[]", "null", "", None):
        try:
            arr = json.loads(dep)
            if arr:
                return False
        except (ValueError, TypeError):
            pass
    return True

counts = {"EFFECTIVE": 0, "CREDIBLE": 0, "RESILIENT": 0, "ZERO-WASTE": 0}
total = 0

for g in gaps:
    if not is_pickable(g):
        continue
    total += 1
    title = g.get("title", "")
    matched = False
    for p in PILLARS:
        if title.upper().startswith(p + ":"):
            counts[p] += 1
            matched = True
            break

print("total=%d" % total)
for p in PILLARS:
    print("%s=%d" % (p, counts[p]))
PYEOF
)" || {
    echo "pillar-balance-check: python3 parse failed" >&2
    exit 2
}

# ── Extract values (Bash 3.2 compat: no assoc arrays) ────────────────────────
_total=0
_effective=0
_credible=0
_resilient=0
_zero_waste=0

while IFS='=' read -r _key _val; do
    case "$_key" in
        total)      _total="${_val:-0}" ;;
        EFFECTIVE)  _effective="${_val:-0}" ;;
        CREDIBLE)   _credible="${_val:-0}" ;;
        RESILIENT)  _resilient="${_val:-0}" ;;
        ZERO-WASTE) _zero_waste="${_val:-0}" ;;
    esac
done <<_COUNTS_EOF
$COUNTS
_COUNTS_EOF

if [ "$QUIET" -eq 0 ]; then
    echo "=== Pillar balance check (INFRA-902) ==="
    echo "Total pickable: $_total  (floor=$FLOOR, overweight>${OVERWEIGHT_PCT}%)"
    echo "  EFFECTIVE:  $_effective"
    echo "  CREDIBLE:   $_credible"
    echo "  RESILIENT:  $_resilient"
    echo "  ZERO-WASTE: $_zero_waste"
fi

ALERT_FIRED=0
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

_emit() {
    local _ev="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] would emit: $_ev"
    else
        # BLOCKER(2): mkdir -p before >> AMBIENT
        mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
        # scanner-anchor: "kind":"pillar_balance_alert"
        # scanner-anchor: "kind":"pillar_balance_overweight"
        printf '%s\n' "$_ev" >> "$AMBIENT" 2>/dev/null || true
    fi
    ALERT_FIRED=1
}

# ── Under-floor check ─────────────────────────────────────────────────────────
for _pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    case "$_pillar" in
        EFFECTIVE)  _count=$_effective ;;
        CREDIBLE)   _count=$_credible ;;
        RESILIENT)  _count=$_resilient ;;
        ZERO-WASTE) _count=$_zero_waste ;;
    esac
    if [ "${_count:-0}" -lt "$FLOOR" ]; then
        _ev="$(printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":%d}' \
            "$TS" "$_pillar" "${_count:-0}" "$FLOOR")"
        if [ "$QUIET" -eq 0 ]; then
            echo "ALERT: pillar $_pillar has only ${_count:-0} pickable gap(s) (floor=$FLOOR)"
        fi
        _emit "$_ev"
    fi
done

# ── Overweight check (pillar > OVERWEIGHT_PCT% of total) ──────────────────────
if [ "${_total:-0}" -gt 0 ]; then
    for _pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
        case "$_pillar" in
            EFFECTIVE)  _count=$_effective ;;
            CREDIBLE)   _count=$_credible ;;
            RESILIENT)  _count=$_resilient ;;
            ZERO-WASTE) _count=$_zero_waste ;;
        esac
        _pct=$(( ${_count:-0} * 100 / _total ))
        if [ "$_pct" -gt "$OVERWEIGHT_PCT" ]; then
            _ev="$(printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}' \
                "$TS" "$_pillar" "${_count:-0}" "$_pct")"
            if [ "$QUIET" -eq 0 ]; then
                echo "WARN: pillar $_pillar is overweight: ${_count:-0}/$_total = ${_pct}% (>${OVERWEIGHT_PCT}%)"
            fi
            _emit "$_ev"
        fi
    done
fi

if [ "$ALERT_FIRED" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    echo "OK: all pillars in balance"
fi

exit "$ALERT_FIRED"
