#!/usr/bin/env bash
# INFRA-423 — verify ambient.jsonl rotation is installed + size in bounds.
#
# Without rotation (INFRA-122), ambient.jsonl grows ~4MB/day under fleet
# load and reaches multi-GB over weeks. The fix exists
# (scripts/setup/install-ambient-rotate-launchd.sh) but is dogfood-machine-
# specific. This script audits the actual launchd job + current size +
# emits ambient ALERTs.

set -euo pipefail

SIZE_ALERT_MB="${AMBIENT_SIZE_ALERT_MB:-50}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

emit_alert() {
    local kind="$1" detail="$2"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"event":"alert","kind":"%s","ts":"%s","detail":%s}\n' \
        "$kind" "$TS" "$detail" >> "$AMBIENT" 2>/dev/null || true
}

# 1. Does ambient.jsonl exist?
if [[ ! -f "$AMBIENT" ]]; then
    echo "[ambient-audit] $AMBIENT does not exist (no fleet activity yet)"
    exit 0
fi

# 2. Is the launchd job loaded? (macOS dogfood machines.)
if [[ "$(uname -s)" == "Darwin" ]]; then
    if launchctl list 2>/dev/null | grep -q dev.chump.ambient-rotate; then
        echo "[ambient-audit] launchd job dev.chump.ambient-rotate is loaded"
    else
        echo "[ambient-audit] launchd job NOT loaded"
        echo "[ambient-audit]   install: scripts/setup/install-ambient-rotate-launchd.sh"
        emit_alert "ambient_rotate_not_installed" \
            "\"launchctl list shows no dev.chump.ambient-rotate\""
    fi
fi

# 3. Current size in bounds?
if command -v stat >/dev/null 2>&1; then
    size_bytes=$(stat -f%z "$AMBIENT" 2>/dev/null || stat -c%s "$AMBIENT" 2>/dev/null || echo 0)
    size_mb=$(( size_bytes / 1024 / 1024 ))
    echo "[ambient-audit] current size: ${size_mb}MB (alert threshold: ${SIZE_ALERT_MB}MB)"
    if [[ "$size_mb" -gt "$SIZE_ALERT_MB" ]]; then
        echo "[ambient-audit] OVER THRESHOLD — rotation not running (or rotation script broken)"
        emit_alert "ambient_oversize" \
            "{\"size_mb\":${size_mb},\"threshold_mb\":${SIZE_ALERT_MB}}"
    fi
fi

# 4. Are there any rotated archives at all? (a healthy machine should have
#    at least one .gz after a week of fleet activity)
shopt -s nullglob
archives=( "$(dirname "$AMBIENT")"/ambient.jsonl.*.gz )
shopt -u nullglob
echo "[ambient-audit] rotated archives present: ${#archives[@]}"

exit 0
