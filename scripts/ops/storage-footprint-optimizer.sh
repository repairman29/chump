#!/usr/bin/env bash
# storage-footprint-optimizer.sh — RESILIENT-323
#
# The ADAPTIVE layer that ZERO-WASTE-053 (cargo-sweep-gc) and INFRA-2303
# (sccache-reaper) were missing: both organs previously ran with FIXED caps
# (CHUMP_CARGO_TARGET_CAP_MB=20000, SCCACHE_CACHE_CAP_GB=10) regardless of
# this node's actual disk headroom or how fast the target/cache are growing.
# That is REACTIVE reaping, not LEARNING.
#
# This organ: SENSE (snapshot target/sccache/docs-archive sizes + disk free +
# cores) -> LEARN (growth rate over a lookback window from history) ->
# BUDGET (derive a disk-aware, growth-aware cap per organ) -> WRITE (an env
# file the existing reapers source, so the budget is ENFORCED without
# duplicating any eviction logic).
#
# Usage:
#   storage-footprint-optimizer.sh [--dry-run]
#
# Env:
#   CHUMP_REPO                    repo root (default: git toplevel, else ~/Projects/chump)
#   CHUMP_STATE_DIR                state dir (default ~/.chump)
#   CHUMP_STORAGE_HISTORY_FILE     snapshot history (default $CHUMP_STATE_DIR/storage-footprint-history.jsonl)
#   CHUMP_STORAGE_BUDGET_FILE      computed-budget output (default $CHUMP_STATE_DIR/storage-footprint-budget.env)
#   CHUMP_STORAGE_LOOKBACK_DAYS    growth-rate window (default 7)
#   CHUMP_STORAGE_DISK_FRACTION    max fraction of free disk the target cap may claim (default 0.25)
#   CHUMP_STORAGE_HISTORY_MAX      max snapshots retained (default 500; bounds the learner's own footprint)
set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/Projects/chump")}}"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
HISTORY="${CHUMP_STORAGE_HISTORY_FILE:-$STATE_DIR/storage-footprint-history.jsonl}"
BUDGET_FILE="${CHUMP_STORAGE_BUDGET_FILE:-$STATE_DIR/storage-footprint-budget.env}"
LOOKBACK_DAYS="${CHUMP_STORAGE_LOOKBACK_DAYS:-7}"
DISK_FRACTION="${CHUMP_STORAGE_DISK_FRACTION:-0.25}"
HISTORY_MAX="${CHUMP_STORAGE_HISTORY_MAX:-500}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$STATE_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { [[ -d "$(dirname "$AMBIENT")" ]] && printf '{"ts":"%s",%s}\n' "$(ts)" "$1" >> "$AMBIENT" 2>/dev/null || true; }
# Scanner anchor for the event-registry verify rule:
#   "kind":"storage_footprint_budget"

du_mb() { [[ -d "$1" ]] && du -sm "$1" 2>/dev/null | awk '{print $1}' || echo 0; }

# ── SENSE ────────────────────────────────────────────────────────────────
TARGET_DIR="$REPO_ROOT/target"
SCCACHE_DIR="${SCCACHE_DIR:-$HOME/.cache/sccache}"
[[ -d "$HOME/Library/Caches/Mozilla.sccache" ]] && SCCACHE_DIR="$HOME/Library/Caches/Mozilla.sccache"
ARCHIVE_DIR="$REPO_ROOT/docs/archive"

TARGET_MB="$(du_mb "$TARGET_DIR")"
SCCACHE_MB="$(du_mb "$SCCACHE_DIR")"
ARCHIVE_MB="$(du_mb "$ARCHIVE_DIR")"
CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Disk-free for the volume the repo lives on (portable df -Pm; works on both
# GNU and BSD/macOS df).
DISK_LINE="$(df -Pm "$REPO_ROOT" 2>/dev/null | awk 'NR==2')"
DISK_FREE_MB="$(echo "$DISK_LINE" | awk '{print $4}')"
DISK_FREE_MB="${DISK_FREE_MB:-0}"
DISK_TOTAL_MB="$(echo "$DISK_LINE" | awk '{print $2}')"
DISK_TOTAL_MB="${DISK_TOTAL_MB:-1}"

NOW_EPOCH="$(date -u +%s)"
printf '{"ts":"%s","epoch":%d,"target_mb":%d,"sccache_mb":%d,"archive_mb":%d,"disk_free_mb":%d,"cores":%d}\n' \
    "$(ts)" "$NOW_EPOCH" "$TARGET_MB" "$SCCACHE_MB" "$ARCHIVE_MB" "$DISK_FREE_MB" "$CORES" >> "$HISTORY"

# Bound the learner's own footprint (RESILIENT-323 must not itself become an
# unbounded-growth organ): keep only the most recent HISTORY_MAX lines.
if [[ "$(wc -l < "$HISTORY" 2>/dev/null || echo 0)" -gt "$HISTORY_MAX" ]]; then
    tail -n "$HISTORY_MAX" "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
fi

# ── LEARN: growth rate over the lookback window ─────────────────────────
LOOKBACK_EPOCH=$((NOW_EPOCH - LOOKBACK_DAYS * 86400))
BASELINE_LINE="$(awk -F'"epoch":' -v cutoff="$LOOKBACK_EPOCH" '
  NF>1 { split($2,a,","); e=a[1]+0; if (e<=cutoff) { last=$0 } }
  END { print last }' "$HISTORY")"

TARGET_GROWTH_MB_DAY=0
SCCACHE_GROWTH_MB_DAY=0
if [[ -n "$BASELINE_LINE" ]]; then
    b_epoch="$(echo "$BASELINE_LINE" | grep -oE '"epoch":[0-9]+' | cut -d: -f2)"
    b_target="$(echo "$BASELINE_LINE" | grep -oE '"target_mb":[0-9]+' | cut -d: -f2)"
    b_sccache="$(echo "$BASELINE_LINE" | grep -oE '"sccache_mb":[0-9]+' | cut -d: -f2)"
    elapsed_days=$(( (NOW_EPOCH - b_epoch) / 86400 ))
    if [[ "$elapsed_days" -gt 0 ]]; then
        TARGET_GROWTH_MB_DAY=$(( (TARGET_MB - b_target) / elapsed_days ))
        SCCACHE_GROWTH_MB_DAY=$(( (SCCACHE_MB - b_sccache) / elapsed_days ))
    fi
fi
# Growth rate is a LEARNING signal, not itself a shrink lever — a one-off
# reap can make it deeply negative and we must not let that invert the cap
# logic below.
(( TARGET_GROWTH_MB_DAY < 0 )) && TARGET_GROWTH_MB_DAY=0
(( SCCACHE_GROWTH_MB_DAY < 0 )) && SCCACHE_GROWTH_MB_DAY=0

# ── BUDGET: disk-aware + cores-aware + growth-aware caps ────────────────
# Disk-aware ceiling: never let the target cap claim more than DISK_FRACTION
# of what's currently free (protects headroom for builds/worktrees/logs).
DISK_CEILING_MB="$(awk -v f="$DISK_FREE_MB" -v r="$DISK_FRACTION" 'BEGIN{printf "%d", f*r}')"
DEFAULT_CAP_MB=20000
TARGET_CAP_MB="$DEFAULT_CAP_MB"
(( DISK_CEILING_MB < TARGET_CAP_MB )) && TARGET_CAP_MB="$DISK_CEILING_MB"
(( TARGET_CAP_MB < 2000 )) && TARGET_CAP_MB=2000   # floor: a cap this fast to plateau over a build cycle is unusable

# Growth-aware TTL: fast growth against a tight cap means the plateau needs
# more frequent pruning to stay bounded rather than sawtooth-spiking against
# the cap. Default 14 days (RESILIENT-239); tighten toward a 3-day floor as
# the days-to-fill-the-cap shrinks.
TIME_DAYS=14
if (( TARGET_GROWTH_MB_DAY > 0 )); then
    DAYS_TO_FILL=$(( TARGET_CAP_MB / TARGET_GROWTH_MB_DAY ))
    if (( DAYS_TO_FILL < TIME_DAYS )); then
        TIME_DAYS="$DAYS_TO_FILL"
        (( TIME_DAYS < 3 )) && TIME_DAYS=3
    fi
fi

# sccache cap: cores-aware (more cores -> more parallel rustc-wrapper
# invocations -> a bigger cache pays off) but disk-bounded like the target.
SCCACHE_CAP_GB=$(( 5 + CORES / 2 ))
(( SCCACHE_CAP_GB > 30 )) && SCCACHE_CAP_GB=30
DISK_CEILING_GB=$(( DISK_CEILING_MB / 1024 ))
if (( DISK_CEILING_GB > 0 && SCCACHE_CAP_GB > DISK_CEILING_GB )); then
    SCCACHE_CAP_GB="$DISK_CEILING_GB"
fi
(( SCCACHE_CAP_GB < 2 )) && SCCACHE_CAP_GB=2

DISK_FREE_PCT=0
(( DISK_TOTAL_MB > 0 )) && DISK_FREE_PCT="$(awk -v f="$DISK_FREE_MB" -v t="$DISK_TOTAL_MB" 'BEGIN{printf "%d", (f/t)*100}')"

# ── WRITE: budget env file, sourced (`:=`-style) by the enforcing organs
# so an operator/CI override always wins and an absent budget file is a
# harmless no-op (cargo-sweep-gc.sh / sccache-reaper.sh keep their own
# hardcoded defaults).
if [[ "$DRY_RUN" -eq 0 ]]; then
    cat > "$BUDGET_FILE.tmp" <<EOF
# Generated by scripts/ops/storage-footprint-optimizer.sh (RESILIENT-323) — do not edit by hand.
# Computed $(ts) from $LOOKBACK_DAYS-day growth: target=+${TARGET_GROWTH_MB_DAY}MB/day sccache=+${SCCACHE_GROWTH_MB_DAY}MB/day
# disk_free=${DISK_FREE_MB}MB (${DISK_FREE_PCT}%) cores=${CORES}
: "\${CHUMP_CARGO_TARGET_CAP_MB:=${TARGET_CAP_MB}}"
: "\${CHUMP_CARGO_SWEEP_TIME_DAYS:=${TIME_DAYS}}"
: "\${SCCACHE_CACHE_CAP_GB:=${SCCACHE_CAP_GB}}"
export CHUMP_CARGO_TARGET_CAP_MB CHUMP_CARGO_SWEEP_TIME_DAYS SCCACHE_CACHE_CAP_GB
EOF
    mv "$BUDGET_FILE.tmp" "$BUDGET_FILE"
fi

echo "[storage-footprint-optimizer] target=${TARGET_MB}MB(+${TARGET_GROWTH_MB_DAY}MB/d) sccache=${SCCACHE_MB}MB(+${SCCACHE_GROWTH_MB_DAY}MB/d) archive=${ARCHIVE_MB}MB disk_free=${DISK_FREE_MB}MB(${DISK_FREE_PCT}%) -> cap=${TARGET_CAP_MB}MB ttl=${TIME_DAYS}d sccache_cap=${SCCACHE_CAP_GB}GB $([ "$DRY_RUN" -eq 1 ] && echo '(dry-run, not written)')"

emit "\"kind\":\"storage_footprint_budget\",\"target_mb\":$TARGET_MB,\"target_growth_mb_day\":$TARGET_GROWTH_MB_DAY,\"sccache_mb\":$SCCACHE_MB,\"sccache_growth_mb_day\":$SCCACHE_GROWTH_MB_DAY,\"archive_mb\":$ARCHIVE_MB,\"disk_free_mb\":$DISK_FREE_MB,\"disk_free_pct\":$DISK_FREE_PCT,\"cores\":$CORES,\"cap_mb\":$TARGET_CAP_MB,\"time_days\":$TIME_DAYS,\"sccache_cap_gb\":$SCCACHE_CAP_GB,\"dry_run\":$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"

exit 0
