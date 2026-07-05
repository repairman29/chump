#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Counts pickable (P0|P1, xs|s|m, no TODO ACs, no blocked deps) gaps per pillar
# (EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE) and emits ambient alerts when
# balance thresholds are breached.
#
# Bash 3.2 compatible (macOS /bin/bash) — no declare -A/-n/mapfile/readarray.
#
# Usage:
#   pillar-balance-check.sh [--dry-run]
#
# Env overrides (for testing):
#   CHUMP_BIN           path to chump binary (default: resolved via cargo metadata)
#   CHUMP_REPO          repo root (default: git rev-parse --show-toplevel)
#   CHUMP_AMBIENT_LOG   override ambient.jsonl path
#
# Exit codes:
#   0 — no alerts; pillars are balanced
#   1 — one or more balance alerts fired
#   2 — fatal error (chump binary missing, etc.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ── Ambient log setup ──────────────────────────────────────────────────────────
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

emit() {
    local kind="$1"; shift
    printf '{"ts":"%s","kind":"%s",%s}\n' "$(ts)" "$kind" "$*" \
        >> "$AMBIENT" 2>/dev/null || true
}

log() { printf '[pillar-balance-check] %s\n' "$*" >&2; }

# ── Resolve chump binary ───────────────────────────────────────────────────────
if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "$CHUMP_BIN" ]]; then
    BIN="$CHUMP_BIN"
else
    # Try cargo metadata target_directory (INFRA-481 shares target dir)
    target_dir=""
    if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
        target_dir=$(cargo metadata --no-deps --format-version 1 \
            --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
            | grep -o '"target_directory":"[^"]*"' \
            | sed 's/"target_directory":"//;s/"//')
    fi
    if [[ -n "$target_dir" ]] && [[ -x "$target_dir/debug/chump" ]]; then
        BIN="$target_dir/debug/chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump >/dev/null 2>&1; then
        BIN="chump"
    else
        log "FATAL: chump binary not found; set CHUMP_BIN or build first"
        exit 2
    fi
fi

export CHUMP_BIN="$BIN"

# ── Collect open gaps ──────────────────────────────────────────────────────────
# Output format: [open] ID — title (Pn/effort)
open_gaps=$("$BIN" gap list --status open 2>/dev/null) || {
    log "FATAL: 'chump gap list --status open' failed"
    exit 2
}

# ── Count pickable gaps per pillar ─────────────────────────────────────────────
# Pickable: P0 or P1, effort xs|s|m.
# Pillar assigned by first matching keyword in title (uppercase).
eff_count=0
cre_count=0
res_count=0
zw_count=0
total_pickable=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Extract priority and effort from trailing "(Pn/effort)"
    prio_effort="${line##*(}"
    prio_effort="${prio_effort%)*}"
    prio="${prio_effort%%/*}"
    effort="${prio_effort##*/}"

    # Pickable: P0 or P1 AND effort xs, s, or m
    case "$prio" in
        P0|P1) ;;
        *) continue ;;
    esac
    case "$effort" in
        xs|s|m) ;;
        *) continue ;;
    esac

    # Extract title (between " — " and " (Pn/...")
    title="${line#* — }"
    title="${title% (*}"
    title_up=$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')

    total_pickable=$((total_pickable + 1))

    # Assign to first matching pillar
    case "$title_up" in
        *EFFECTIVE*)  eff_count=$((eff_count + 1)) ;;
        *CREDIBLE*)   cre_count=$((cre_count + 1)) ;;
        *RESILIENT*)  res_count=$((res_count + 1)) ;;
        *ZERO-WASTE*) zw_count=$((zw_count + 1)) ;;
    esac
done <<EOF
$open_gaps
EOF

# ── Evaluate thresholds ────────────────────────────────────────────────────────
FLOOR=2
alert_fired=0

check_underweight() {
    local pillar="$1"
    local count="$2"
    if [[ "$count" -lt "$FLOOR" ]]; then
        log "ALERT: $pillar underweight — count=$count < floor=$FLOOR"
        emit "pillar_balance_alert" \
            "\"pillar\":\"$pillar\",\"count\":$count,\"floor\":$FLOOR"
        alert_fired=1
    fi
}

check_overweight() {
    local pillar="$1"
    local count="$2"
    if [[ "$total_pickable" -gt 0 ]]; then
        # count > 50% of total: count * 2 > total
        if [[ $((count * 2)) -gt "$total_pickable" ]]; then
            # Compute pct as integer (count * 100 / total)
            pct=$((count * 100 / total_pickable))
            log "ALERT: $pillar overweight — count=$count pct=${pct}% total=$total_pickable"
            emit "pillar_balance_overweight" \
                "\"pillar\":\"$pillar\",\"count\":$count,\"pct\":$pct,\"total\":$total_pickable"
            alert_fired=1
        fi
    fi
}

check_underweight "EFFECTIVE"  "$eff_count"
check_underweight "CREDIBLE"   "$cre_count"
check_underweight "RESILIENT"  "$res_count"
check_underweight "ZERO-WASTE" "$zw_count"

check_overweight "EFFECTIVE"  "$eff_count"
check_overweight "CREDIBLE"   "$cre_count"
check_overweight "RESILIENT"  "$res_count"
check_overweight "ZERO-WASTE" "$zw_count"

# ── Summary output ─────────────────────────────────────────────────────────────
printf 'Pillar balance: EFFECTIVE=%d CREDIBLE=%d RESILIENT=%d ZERO-WASTE=%d  (of %d pickable)\n' \
    "$eff_count" "$cre_count" "$res_count" "$zw_count" "$total_pickable"

if [[ "$alert_fired" -eq 1 ]]; then
    printf 'Status: ALERTS FIRED (see ambient.jsonl)\n'
    exit 1
else
    printf 'Status: OK\n'
    exit 0
fi
