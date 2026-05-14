#!/usr/bin/env bash
# cargo-target-reaper.sh — INFRA-1250
# Reclaim stale cargo build artifacts (60GB+ unbounded growth).
#
# Usage:
#   bash scripts/ops/cargo-target-reaper.sh [--execute] [--fingerprint-age-d N] [--fleet-age-d N]
#
# By default: dry-run only. Pass --execute to actually delete.
#
# Reaps:
#   (a) target/debug/.fingerprint/*        mtime > FINGERPRINT_AGE_D days
#   (b) target/debug/deps/lib*.rlib        mtime > FINGERPRINT_AGE_D days
#   (c) ~/.cache/chump-fleet-target/<dir>/ mtime > FLEET_AGE_D days AND
#       no live process has CARGO_TARGET_DIR pointing at <dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EXECUTE=0
FINGERPRINT_AGE_D="${CHUMP_CARGO_REAPER_FINGERPRINT_AGE_D:-14}"
FLEET_AGE_D="${CHUMP_CARGO_REAPER_FLEET_AGE_D:-7}"
MIN_FREE_GB=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)            EXECUTE=1 ;;
        --fingerprint-age-d)  FINGERPRINT_AGE_D="$2"; shift ;;
        --fleet-age-d)        FLEET_AGE_D="$2"; shift ;;
        --help|-h)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── Safety guards ────────────────────────────────────────────────────────────

# 1. Refuse if any cargo process is active
if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    echo "[cargo-target-reaper] ABORT: active cargo/rustc processes detected — run after build completes." >&2
    exit 1
fi

# 2. Refuse if free disk < MIN_FREE_GB
_free_kb=$(df -k "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
_free_gb=$(( _free_kb / 1024 / 1024 ))
if [[ $_free_gb -lt $MIN_FREE_GB ]]; then
    echo "[cargo-target-reaper] ABORT: only ${_free_gb}GB free — less than minimum ${MIN_FREE_GB}GB." >&2
    exit 1
fi

AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"
_dry_label="[DRY-RUN]"
[[ $EXECUTE -eq 1 ]] && _dry_label=""

_total_bytes=0
_reaped_count=0

# ── Helper: maybe_delete ─────────────────────────────────────────────────────
# Usage: maybe_delete <path>
maybe_delete() {
    local path="$1"
    local size_bytes=0
    if [[ -d "$path" ]]; then
        size_bytes=$(du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    elif [[ -f "$path" ]]; then
        size_bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
    fi
    local age_days=0
    age_days=$(( ( $(date +%s) - $(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  reap: ${path} (${age_days}d old, ~$(( size_bytes / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$path"
    fi
    _total_bytes=$(( _total_bytes + size_bytes ))
    _reaped_count=$(( _reaped_count + 1 ))
    # Emit per-artifact ambient event
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$size_bytes" "$age_days" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── (a+b) main repo target/debug ─────────────────────────────────────────────
TARGET_DEBUG="${REPO_ROOT}/target/debug"
if [[ -d "$TARGET_DEBUG" ]]; then
    echo "[cargo-target-reaper] Scanning ${TARGET_DEBUG}/.fingerprint/* (>${FINGERPRINT_AGE_D}d)…"
    while IFS= read -r -d '' entry; do
        maybe_delete "$entry"
    done < <(find "${TARGET_DEBUG}/.fingerprint" -mindepth 1 -maxdepth 1 -mtime "+${FINGERPRINT_AGE_D}" -print0 2>/dev/null)

    echo "[cargo-target-reaper] Scanning ${TARGET_DEBUG}/deps/lib*.rlib (>${FINGERPRINT_AGE_D}d)…"
    while IFS= read -r -d '' entry; do
        maybe_delete "$entry"
    done < <(find "${TARGET_DEBUG}/deps" -maxdepth 1 -name 'lib*.rlib' -mtime "+${FINGERPRINT_AGE_D}" -print0 2>/dev/null)
fi

# ── (c) fleet shared target dirs ─────────────────────────────────────────────
FLEET_CACHE="${HOME}/.cache/chump-fleet-target"
if [[ -d "$FLEET_CACHE" ]]; then
    echo "[cargo-target-reaper] Scanning ${FLEET_CACHE}/ (>${FLEET_AGE_D}d, no live owner)…"
    # Collect all CARGO_TARGET_DIR values from live processes
    _live_targets=""
    while IFS= read -r pid; do
        _env=$(ps eww -p "$pid" 2>/dev/null | grep -o 'CARGO_TARGET_DIR=[^ ]*' | head -1 || true)
        if [[ -n "$_env" ]]; then
            _live_targets="${_live_targets}${_env##*=}"$'\n'
        fi
    done < <(pgrep -f "cargo|rustc" 2>/dev/null || true)

    while IFS= read -r -d '' dir; do
        _basename=$(basename "$dir")
        # Skip if any live process references this dir
        if echo "$_live_targets" | grep -qF "$_basename" 2>/dev/null; then
            echo "  skip (live owner): ${dir}"
            continue
        fi
        maybe_delete "$dir"
    done < <(find "$FLEET_CACHE" -mindepth 1 -maxdepth 1 -type d -mtime "+${FLEET_AGE_D}" -print0 2>/dev/null)
fi

# ── Summary ──────────────────────────────────────────────────────────────────
_total_mb=$(( _total_bytes / 1024 / 1024 ))
echo ""
echo "[cargo-target-reaper] ${_dry_label} Done: ${_reaped_count} artifacts, ~${_total_mb}MB"
if [[ $EXECUTE -eq 0 && $_reaped_count -gt 0 ]]; then
    echo "[cargo-target-reaper] Re-run with --execute to actually delete."
fi

# Summary ambient event
printf '{"ts":"%s","kind":"cargo_target_reaper_summary","reaped_count":%d,"bytes_freed":%d,"execute":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_reaped_count" "$_total_bytes" \
    "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
    >> "$AMBIENT_LOG" 2>/dev/null || true
