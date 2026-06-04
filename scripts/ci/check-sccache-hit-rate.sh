#!/usr/bin/env bash
# scripts/ci/check-sccache-hit-rate.sh — CREDIBLE-085 (2026-06-04)
#
# Post-build gate: parses `sccache --show-stats` and fails the build when
# the cache hit rate is below CHUMP_SCCACHE_HIT_RATE_MIN (default 10 %).
#
# WHY THIS EXISTS
#
# sccache silently degrades when its R2 credentials rotate or the bucket
# becomes unreachable — every build hits the cache, every lookup misses,
# CI keeps going at warm-cache speed expectations but pays cold-cache
# wall-clock. Worse: the substrate health signal (sccache_hit_rate_low) is
# never emitted, so the operator has no idea the cred-rot happened.
#
# This gate is the cheapest correct signal: a single threshold check
# after a build. Hit rate at 0 % on a .rs-touching PR = something is
# wrong with sccache (creds rotated, bucket gone, server unreachable).
#
# Cold-cache invocations (brand-new branch, first build on a runner, deep
# clean) legitimately hit ~0 %. Use CHUMP_SCCACHE_HIT_RATE_CHECK=0 with a
# Sccache-Hit-Rate-Bypass: trailer to opt out — audited via ambient.
#
# USAGE
#
#   bash scripts/ci/check-sccache-hit-rate.sh
#     (reads `sccache --show-stats` from PATH; exits 1 if rate < threshold)
#
#   STATS_FROM_FILE=/path/to/captured-stats.txt bash scripts/ci/check-...
#     (use a captured stats file — useful for smoke tests + repro)
#
# ENV
#
#   CHUMP_SCCACHE_HIT_RATE_MIN     default 10 (percent)
#   CHUMP_SCCACHE_HIT_RATE_CHECK   set to 0 to skip the gate (cold-cache)
#   CHUMP_AMBIENT_LOG              default $REPO_ROOT/.chump-locks/ambient.jsonl
#   STATS_FROM_FILE                use stats from file instead of `sccache`
#
# EXIT
#
#   0 — hit rate >= threshold OR check skipped via env bypass
#   1 — hit rate < threshold (substrate alert; build fails)
#   2 — sccache binary not found AND no STATS_FROM_FILE
#   3 — parser couldn't extract hit rate from stats output

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defaults (operator-tunable)
THRESHOLD="${CHUMP_SCCACHE_HIT_RATE_MIN:-10}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# Self-bypass (cold cache, etc.)
if [[ "${CHUMP_SCCACHE_HIT_RATE_CHECK:-1}" = "0" ]]; then
    echo "[sccache-hit-rate] SKIP — CHUMP_SCCACHE_HIT_RATE_CHECK=0 set" >&2
    # Audit the bypass on ambient so the operator can see how often it fires.
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"sccache_hit_rate_check_bypassed","source":"check-sccache-hit-rate","reason":"CHUMP_SCCACHE_HIT_RATE_CHECK=0"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
    exit 0
fi

# ── Get stats output ──────────────────────────────────────────────────────
STATS=""
if [[ -n "${STATS_FROM_FILE:-}" ]]; then
    if [[ ! -r "$STATS_FROM_FILE" ]]; then
        echo "[sccache-hit-rate] STATS_FROM_FILE=$STATS_FROM_FILE not readable" >&2
        exit 2
    fi
    STATS="$(cat "$STATS_FROM_FILE")"
elif command -v sccache >/dev/null 2>&1; then
    STATS="$(sccache --show-stats 2>/dev/null || true)"
else
    echo "[sccache-hit-rate] sccache not on PATH — install it or set STATS_FROM_FILE" >&2
    exit 2
fi

if [[ -z "$STATS" ]]; then
    echo "[sccache-hit-rate] empty stats output" >&2
    exit 3
fi

# ── Parse 'Cache hits rate    NN.NN %' ────────────────────────────────────
# We want the line WITHOUT a per-language qualifier (Assembler, C/C++, Rust).
HIT_RATE_LINE="$(printf '%s\n' "$STATS" | grep -E '^Cache hits rate[[:space:]]+[0-9.]+[[:space:]]*%' | head -1)"
if [[ -z "$HIT_RATE_LINE" ]]; then
    echo "[sccache-hit-rate] could not find 'Cache hits rate' line in stats" >&2
    echo "─── stats output (first 20 lines): ───" >&2
    printf '%s\n' "$STATS" | head -20 >&2
    exit 3
fi

# Extract the integer percent (sccache prints e.g. "36.49 %"; floor to int).
HIT_RATE_PCT="$(printf '%s\n' "$HIT_RATE_LINE" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
HIT_RATE_INT="${HIT_RATE_PCT%.*}"
HIT_RATE_INT="${HIT_RATE_INT:-0}"

# Strip leading zeros so bash arithmetic doesn't parse as octal.
HIT_RATE_INT="$((10#${HIT_RATE_INT}))"

echo "[sccache-hit-rate] measured rate: ${HIT_RATE_PCT}% (threshold: ${THRESHOLD}%)" >&2

# ── Compare against threshold ─────────────────────────────────────────────
#
# DEFAULT: WARN-ONLY. The gate emits the substrate-health event and prints
# diagnostics but exits 0 unless CHUMP_SCCACHE_HIT_RATE_ENFORCE=1. This
# matches EFFECTIVE-094 ratchet-down discipline — observe + tune + then
# promote to fail-build once the threshold is calibrated. Today's measured
# rate on a typical cargo-test job is in the 5-10% band; raising the
# threshold to fail-mode before tuning would block every PR.
#
# To enforce: set CHUMP_SCCACHE_HIT_RATE_ENFORCE=1 (typically in
# .github/workflows/ci.yml on the post-build step).
ENFORCE="${CHUMP_SCCACHE_HIT_RATE_ENFORCE:-0}"

if [[ "$HIT_RATE_INT" -lt "$THRESHOLD" ]]; then
    if [[ "$ENFORCE" = "1" ]]; then
        echo "[sccache-hit-rate] FAIL — hit rate ${HIT_RATE_PCT}% < ${THRESHOLD}% threshold (ENFORCE=1)" >&2
    else
        echo "[sccache-hit-rate] WARN — hit rate ${HIT_RATE_PCT}% < ${THRESHOLD}% threshold (warn-only; set CHUMP_SCCACHE_HIT_RATE_ENFORCE=1 to fail build)" >&2
    fi
    echo "[sccache-hit-rate] Likely causes:" >&2
    echo "[sccache-hit-rate]   - R2 credentials rotated (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)" >&2
    echo "[sccache-hit-rate]   - SCCACHE_BUCKET / SCCACHE_ENDPOINT misconfigured" >&2
    echo "[sccache-hit-rate]   - sccache server unreachable" >&2
    echo "[sccache-hit-rate]   - cold cache (brand-new branch or runner) — bypass: CHUMP_SCCACHE_HIT_RATE_CHECK=0" >&2

    # Emit substrate-health signal so the operator + curators see it.
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"sccache_hit_rate_low","source":"check-sccache-hit-rate","measured_pct":"%s","threshold_pct":"%s","commit":"%s","job":"%s","enforced":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$HIT_RATE_PCT" \
        "$THRESHOLD" \
        "${GITHUB_SHA:-${CHUMP_COMMIT_SHA:-unknown}}" \
        "${GITHUB_JOB:-${CHUMP_JOB_NAME:-unknown}}" \
        "$ENFORCE" \
        >> "$AMBIENT_LOG" 2>/dev/null || true

    if [[ "$ENFORCE" = "1" ]]; then
        exit 1
    fi
    # WARN-only mode: event emitted, build continues.
    exit 0
fi

echo "[sccache-hit-rate] PASS — hit rate ${HIT_RATE_PCT}% >= ${THRESHOLD}%" >&2
exit 0
