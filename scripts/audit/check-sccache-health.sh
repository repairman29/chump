#!/usr/bin/env bash
# INFRA-421 — verify sccache is installed + report cache hit rate.
#
# Without sccache (INFRA-202), every fresh worktree pays a 5-15min cold
# cargo check. The fix exists (scripts/setup/install-sccache.sh) but is
# dogfood-machine-specific and not git-tracked (.cargo/config.toml is
# gitignored). This script audits the actual install on the machine
# running it + emits an ambient ALERT when cache hit rate < 70%.
#
# Designed to be safe to run anytime; runs hourly via launchd installer
# scripts/setup/install-sccache-audit-launchd.sh.

set -euo pipefail

THRESHOLD="${SCCACHE_HIT_THRESHOLD:-70}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

emit_alert() {
    local kind="$1" detail="$2"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"event":"alert","kind":"%s","ts":"%s","detail":%s}\n' \
        "$kind" "$TS" "$detail" >> "$AMBIENT" 2>/dev/null || true
}

# 1. Is sccache installed?
if ! command -v sccache >/dev/null 2>&1; then
    echo "[sccache-audit] sccache binary not found on PATH"
    echo "[sccache-audit]   install: scripts/setup/install-sccache.sh"
    emit_alert "sccache_not_installed" "\"sccache binary missing on PATH\""
    exit 0
fi

# 2. Is rustc-wrapper configured?
if [[ ! -f "$REPO_ROOT/.cargo/config.toml" ]] \
        || ! grep -q 'rustc-wrapper.*sccache' "$REPO_ROOT/.cargo/config.toml" 2>/dev/null; then
    echo "[sccache-audit] sccache installed but .cargo/config.toml not wired"
    echo "[sccache-audit]   install: scripts/setup/install-sccache.sh"
    emit_alert "sccache_not_configured" "\".cargo/config.toml missing rustc-wrapper line\""
    exit 0
fi

# 3. Report cache hit rate.
stats="$(sccache --show-stats 2>/dev/null || true)"
if [[ -z "$stats" ]]; then
    echo "[sccache-audit] sccache --show-stats produced no output"
    emit_alert "sccache_stats_unavailable" "\"--show-stats returned empty\""
    exit 0
fi

# Parse "Compile requests" / "Cache hits" lines. Format from sccache 0.x:
#   Compile requests                123
#   Cache hits                       89
hits=$(echo "$stats" | awk '/^Cache hits[[:space:]]+[0-9]/{print $3; exit}')
reqs=$(echo "$stats" | awk '/^Compile requests[[:space:]]+[0-9]/{print $3; exit}')
hits="${hits:-0}"; reqs="${reqs:-0}"

if [[ "$reqs" -lt 50 ]]; then
    echo "[sccache-audit] only $reqs compile requests so far — cache still warming, skipping ratio check"
    exit 0
fi

rate=$(( (hits * 100) / reqs ))
echo "[sccache-audit] cache hit rate: ${rate}% (${hits} hits / ${reqs} requests)"

if [[ "$rate" -lt "$THRESHOLD" ]]; then
    echo "[sccache-audit] BELOW THRESHOLD ${THRESHOLD}% — investigate cache eviction / size"
    emit_alert "sccache_low_hit_rate" \
        "{\"rate\":${rate},\"threshold\":${THRESHOLD},\"hits\":${hits},\"requests\":${reqs}}"
fi

exit 0
