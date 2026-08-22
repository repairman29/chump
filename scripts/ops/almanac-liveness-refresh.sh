#!/usr/bin/env bash
# scripts/ops/almanac-liveness-refresh.sh — INFRA-3643 (TREK-17)
#
# WHY THIS EXISTS. scripts/ops/almanac-summarize-watchdog.sh (RESILIENT-354) is
# a launchd-only supervisor — it heals the almanac summarize driver and pages
# on coverage-drop, but ONLY on macOS. The Linux owned-node factory (CJ,
# INFRA-3642) has no almanac liveness/refresh organ at all: a missing or
# stale `almanac` binary on CJ silently degrades fusion search to
# keyword-only with nothing watching for it, the same "designed but never
# wired into the revivable gate" blind spot RESILIENT-366's roll-call test
# exists to catch for systemd timers generally.
#
# This is the systemd-side complement (not a port of the macOS coverage-page
# path — that stays launchd/summarize-driver-specific): it covers the two
# things a Linux factory node actually needs locally —
#
#   1. BINARY PRESENCE — is `almanac` on PATH / at the expected install dir?
#      If not, build it from the tracked almanac checkout (best-effort,
#      mirrors node-refresh-chump.sh's "build from repo" fallback) so a fresh
#      CJ clone doesn't sit with a permanently-missing binary.
#   2. INDEX FRESHNESS — is the last-indexed commit marker (written by
#      scripts/dev/almanac-refresh-guard.py) within the staleness floor of
#      wall-clock time? A marker older than the floor means the refresh loop
#      itself has stopped running, even if rc=0 on its last real cycle.
#
# Usage:
#   scripts/ops/almanac-liveness-refresh.sh              # scan + heal
#   scripts/ops/almanac-liveness-refresh.sh --dry-run     # report only
#
# Env:
#   CHUMP_ALMANAC_BIN            — path to the almanac binary
#                                   (default: $HOME/Projects/almanac/target/release/almanac)
#   CHUMP_ALMANAC_REPO           — path to the almanac source checkout used to
#                                   build the binary if absent
#                                   (default: $HOME/Projects/almanac)
#   CHUMP_ALMANAC_MARKER         — path to the last-indexed-commit marker file
#                                   written by almanac-refresh-guard.py
#                                   (default: $HOME/Projects/almanac.last-indexed-commit)
#   CHUMP_ALMANAC_STALE_FLOOR_S  — max marker age in seconds before flagged
#                                   stale (default 86400 = 24h)
#   CHUMP_AMBIENT_LOG            — override ambient.jsonl path
#
# Exit codes:
#   0  normal (whether or not anything needed healing)
#   1  internal failure only (never for "binary absent, build failed" — that's
#      logged and left for the next cycle, same non-fatal posture as
#      almanac-summarize-watchdog.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

ALMANAC_REPO="${CHUMP_ALMANAC_REPO:-$HOME/Projects/almanac}"
ALMANAC_BIN="${CHUMP_ALMANAC_BIN:-$ALMANAC_REPO/target/release/almanac}"
MARKER="${CHUMP_ALMANAC_MARKER:-${ALMANAC_REPO}.last-indexed-commit}"
STALE_FLOOR_S="${CHUMP_ALMANAC_STALE_FLOOR_S:-86400}"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── 1. Binary presence ──────────────────────────────────────────────────────
built=0
if [[ -x "$ALMANAC_BIN" ]]; then
    echo "[almanac-liveness-refresh] binary present: $ALMANAC_BIN"
else
    echo "[almanac-liveness-refresh] MISSING: $ALMANAC_BIN"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[almanac-liveness-refresh]   (dry-run) would build from $ALMANAC_REPO"
    elif [[ -d "$ALMANAC_REPO" ]] && command -v cargo >/dev/null 2>&1; then
        if (cd "$ALMANAC_REPO" && cargo build --release --bin almanac) >/dev/null 2>&1; then
            echo "[almanac-liveness-refresh]   built binary from $ALMANAC_REPO"
            # scanner-anchor: "kind":"almanac_liveness_binary_built"  (INFRA-3643;
            # fires when the systemd organ finds the almanac binary missing on
            # a Linux factory node and builds it from the tracked checkout)
            emit almanac_liveness_binary_built "\"repo\":\"$ALMANAC_REPO\""
            built=1
        else
            echo "[almanac-liveness-refresh]   WARN: build failed (non-fatal; retried next cycle)" >&2
            # scanner-anchor: "kind":"almanac_liveness_binary_build_failed"
            emit almanac_liveness_binary_build_failed "\"repo\":\"$ALMANAC_REPO\""
        fi
    else
        echo "[almanac-liveness-refresh]   SKIP: no almanac checkout at $ALMANAC_REPO or no cargo on PATH"
    fi
fi

# ── 2. Index freshness ───────────────────────────────────────────────────────
stale=0
marker_age=""
if [[ -f "$MARKER" ]]; then
    marker_mtime="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER" 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    marker_age=$(( now_epoch - marker_mtime ))
    if (( marker_age > STALE_FLOOR_S )); then
        stale=1
        echo "[almanac-liveness-refresh] STALE: index marker is ${marker_age}s old (floor ${STALE_FLOOR_S}s)"
        # scanner-anchor: "kind":"almanac_liveness_index_stale"  (INFRA-3643;
        # fires when the last-indexed-commit marker is older than the
        # staleness floor — the refresh loop itself has stopped moving, even
        # if its last real cycle exited 0)
        emit almanac_liveness_index_stale "\"marker\":\"$MARKER\",\"age_s\":$marker_age,\"floor_s\":$STALE_FLOOR_S,\"dry_run\":$DRY_RUN"
    else
        echo "[almanac-liveness-refresh] index fresh: marker is ${marker_age}s old (floor ${STALE_FLOOR_S}s)"
    fi
else
    echo "[almanac-liveness-refresh] no marker at $MARKER — nothing indexed yet on this node (skip)"
fi

# Heartbeat — always emit so a dead unit is itself observable via ambient.jsonl.
# scanner-anchor: "kind":"almanac_liveness_refresh_tick"  (INFRA-3643; emitted
# every cycle, success or no-op — proof the systemd organ itself is alive)
emit almanac_liveness_refresh_tick "\"built\":$built,\"stale\":$stale,\"marker_age_s\":${marker_age:-null},\"dry_run\":$DRY_RUN"

echo "[almanac-liveness-refresh] cycle complete: built=$built stale=$stale marker_age_s=${marker_age:-n/a} dry_run=$DRY_RUN"
exit 0
