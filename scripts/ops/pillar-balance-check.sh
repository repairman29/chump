#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Reads 'chump gap list --status open', counts pickable (P0|P1, effort xs|s|m)
# gaps per pillar (EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE), then:
#   - Emits kind=pillar_balance_alert when any pillar < FLOOR (default 2)
#   - Emits kind=pillar_balance_overweight when any pillar > 50% of total pickable
#   - Exits non-zero if any alert fired
#
# Bash 3.2 compatible (no declare -A/-n, no mapfile/readarray).
#
# Usage:
#   bash scripts/ops/pillar-balance-check.sh [--json]
#
# Env:
#   CHUMP_BIN               override chump binary path (default: discover via cargo metadata or PATH)
#   CHUMP_REPO              override repo root (default: git rev-parse --show-toplevel)
#   CHUMP_AMBIENT_LOG       override ambient.jsonl path
#   PILLAR_FLOOR            floor count (default: 2)
#   PILLAR_OVERWEIGHT_PCT   overweight threshold percent (default: 50)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Resolve repo root ─────────────────────────────────────────────────────────
if [[ -n "${CHUMP_REPO:-}" ]]; then
    REPO_ROOT="$CHUMP_REPO"
else
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo ".")"
fi

# ── Resolve ambient log path ──────────────────────────────────────────────────
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

# ── Resolve chump binary ──────────────────────────────────────────────────────
if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "${CHUMP_BIN}" ]]; then
    BIN="$CHUMP_BIN"
elif CARGO_TARGET="$(cargo metadata --no-deps --format-version 1 --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null)"; then
    if [[ -x "${CARGO_TARGET}/debug/chump" ]]; then
        BIN="${CARGO_TARGET}/debug/chump"
    elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
        BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    else
        BIN="chump"
    fi
elif command -v chump >/dev/null 2>&1; then
    BIN="chump"
else
    echo "[pillar-balance-check] ERROR: chump binary not found" >&2
    exit 2
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
WANT_JSON=0
for arg in "$@"; do
    case "$arg" in
        --json) WANT_JSON=1 ;;
    esac
done

# ── Configuration ─────────────────────────────────────────────────────────────
FLOOR="${PILLAR_FLOOR:-2}"
OVERWEIGHT_PCT="${PILLAR_OVERWEIGHT_PCT:-50}"

# ── Timestamp helper (Bash 3.2 safe) ─────────────────────────────────────────
now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Fetch open gaps and filter to pickable (P0|P1, effort xs|s|m) ────────────
# Uses wc -l instead of grep -c to avoid non-zero exit on empty input.
ALL_GAPS=$("$BIN" gap list --status open 2>/dev/null) || ALL_GAPS=""

# Filter: line must match priority (P0 or P1) AND effort (xs, s, or m).
PICKABLE=$(printf '%s\n' "$ALL_GAPS" | grep -E '\(P[01]/(xs|s|m)\)') || true

# ── Count per pillar (wc -l is always safe; grep returns all matching lines) ──
count_EFFECTIVE=$(printf '%s\n' "$PICKABLE" | grep -i "EFFECTIVE:" | wc -l | tr -d ' \t')
count_CREDIBLE=$(printf '%s\n' "$PICKABLE" | grep -i "CREDIBLE:" | wc -l | tr -d ' \t')
count_RESILIENT=$(printf '%s\n' "$PICKABLE" | grep -i "RESILIENT:" | wc -l | tr -d ' \t')
count_ZERO_WASTE=$(printf '%s\n' "$PICKABLE" | grep -i "ZERO-WASTE:" | wc -l | tr -d ' \t')

# Ensure numeric (strip any trailing whitespace/newlines)
count_EFFECTIVE=${count_EFFECTIVE:-0}
count_CREDIBLE=${count_CREDIBLE:-0}
count_RESILIENT=${count_RESILIENT:-0}
count_ZERO_WASTE=${count_ZERO_WASTE:-0}

TOTAL=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

ALERTS_FIRED=0

# ── Emit pillar_balance_alert for any pillar below floor ─────────────────────
emit_alert() {
    local pillar="$1"
    local count="$2"
    local ts
    ts="$(now_ts)"
    printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":%d}\n' \
        "$ts" "$pillar" "$count" "$FLOOR" >> "$AMBIENT" 2>/dev/null || true
    echo "[pillar-balance-check] ALERT: pillar $pillar count=$count < floor=$FLOOR"
    ALERTS_FIRED=1
}

# ── Emit pillar_balance_overweight for any pillar > OVERWEIGHT_PCT% ───────────
emit_overweight() {
    local pillar="$1"
    local count="$2"
    local pct="$3"
    local ts
    ts="$(now_ts)"
    printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
        "$ts" "$pillar" "$count" "$pct" >> "$AMBIENT" 2>/dev/null || true
    echo "[pillar-balance-check] OVERWEIGHT: pillar $pillar count=$count pct=$pct% > $OVERWEIGHT_PCT%"
    ALERTS_FIRED=1
}

# ── Check each pillar ─────────────────────────────────────────────────────────
check_pillar() {
    local pillar="$1"
    local count="$2"

    if [[ "$count" -lt "$FLOOR" ]]; then
        emit_alert "$pillar" "$count"
    fi

    if [[ "$TOTAL" -gt 0 ]]; then
        local pct=$(( count * 100 / TOTAL ))
        if [[ "$pct" -gt "$OVERWEIGHT_PCT" ]]; then
            emit_overweight "$pillar" "$count" "$pct"
        fi
    fi
}

check_pillar "EFFECTIVE"  "$count_EFFECTIVE"
check_pillar "CREDIBLE"   "$count_CREDIBLE"
check_pillar "RESILIENT"  "$count_RESILIENT"
check_pillar "ZERO-WASTE" "$count_ZERO_WASTE"

# ── JSON output mode ──────────────────────────────────────────────────────────
if [[ "$WANT_JSON" -eq 1 ]]; then
    printf '{"pillars":{"EFFECTIVE":%d,"CREDIBLE":%d,"RESILIENT":%d,"ZERO-WASTE":%d},"total_pickable":%d,"floor":%d,"alerts_fired":%d}\n' \
        "$count_EFFECTIVE" "$count_CREDIBLE" "$count_RESILIENT" "$count_ZERO_WASTE" \
        "$TOTAL" "$FLOOR" "$ALERTS_FIRED"
else
    echo "[pillar-balance-check] pillars: EFFECTIVE=$count_EFFECTIVE CREDIBLE=$count_CREDIBLE RESILIENT=$count_RESILIENT ZERO-WASTE=$count_ZERO_WASTE total=$TOTAL"
fi

# ── Exit non-zero if any alert fired ─────────────────────────────────────────
if [[ "$ALERTS_FIRED" -eq 1 ]]; then
    exit 1
fi
