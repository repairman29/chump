#!/usr/bin/env bash
# FLEET-033 spike: measure SQLite contention at N=10/30/100 concurrent agents
# Run from repo root: bash scripts/spike/measure-sqlite-contention.sh
#
# INFRA-430: BUG (now fixed) — original script set CHUMP_REPO_ROOT, but the
# chump binary only honors CHUMP_REPO (or CHUMP_HOME). Net effect: every
# `chump gap reserve` call below wrote to the production registry, leaking
# 302 SPIKE-* fixture rows on 2026-05-03 (cleanup: INFRA-428). Two-part
# fix: (1) use the right env var; (2) hard-guard refusing to run if chump's
# effective repo_root resolves anywhere under the host repo.

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

CHUMP_BIN="${CHUMP_BIN:-$(command -v chump)}"
if [ -z "$CHUMP_BIN" ] || [ ! -x "$CHUMP_BIN" ]; then
    echo "Error: chump binary not found or not executable"
    exit 1
fi

# Create a temporary test database and lock monitoring directory
SPIKE_DIR=$(mktemp -d)
LOCK_LOG="$SPIKE_DIR/lock-contention.log"
RESULTS="$SPIKE_DIR/results.json"
trap 'rm -rf "$SPIKE_DIR"' EXIT

mkdir -p "$SPIKE_DIR/.chump"
# INFRA-430: chump honors CHUMP_REPO + CHUMP_HOME (see src/repo_path.rs).
# CHUMP_REPO_ROOT is NOT honored — keeping it set helps human readers
# spot the historical bug, but real isolation comes from CHUMP_REPO.
export CHUMP_REPO="$SPIKE_DIR"
export CHUMP_HOME="$SPIKE_DIR"
export CHUMP_REPO_ROOT="$SPIKE_DIR"  # cosmetic; not honored by chump

# INFRA-430 hard-guard: refuse to run if chump's effective repo_root still
# resolves under $REPO_ROOT (the production checkout). Catches future
# env-var renames or override-bypass scenarios that would otherwise
# silently re-leak fixtures into production state.db.
EFFECTIVE_REPO=$("$CHUMP_BIN" config 2>/dev/null | grep -oE 'repo_root=[^ ,]+' | head -1 | cut -d= -f2)
if [ -n "$EFFECTIVE_REPO" ] && [ "${EFFECTIVE_REPO#$REPO_ROOT}" != "$EFFECTIVE_REPO" ]; then
    echo "ERROR (INFRA-430): chump still resolves repo_root to '$EFFECTIVE_REPO'" >&2
    echo "  which is under the production checkout '$REPO_ROOT'." >&2
    echo "  The CHUMP_REPO env var didn't take effect — refusing to run." >&2
    echo "  Without isolation this would leak fixture rows into production state.db" >&2
    echo "  (see INFRA-428 cleanup for the previous incident)." >&2
    exit 1
fi

# Initialize the database
"$CHUMP_BIN" gap import >/dev/null 2>&1 || true

# Function to simulate concurrent gap operations
measure_contention() {
    local N=$1  # Number of concurrent agents
    local DURATION=$2  # Duration in seconds
    local DOMAIN="SPIKE"

    echo "[measure] N=$N for ${DURATION}s..."

    # Create background workers that perform gap operations
    local pids=()
    local start_time=$(date +%s.%N)
    local end_time=$(($(date +%s) + DURATION))

    for i in $(seq 1 "$N"); do
        (
            while [ "$(date +%s)" -lt "$end_time" ]; do
                # Measure operation latency
                local op_start=$(date +%s.%N)

                # Reserve a gap
                CHUMP_REPO="$SPIKE_DIR" CHUMP_HOME="$SPIKE_DIR" "$CHUMP_BIN" gap reserve \
                    --domain "$DOMAIN" --title "spike-test-$i" --effort xs \
                    >/dev/null 2>&1 || true

                # List gaps (read operation)
                CHUMP_REPO="$SPIKE_DIR" CHUMP_HOME="$SPIKE_DIR" "$CHUMP_BIN" gap list \
                    >/dev/null 2>&1 || true

                local op_end=$(date +%s.%N)
                local latency=$(echo "$op_end - $op_start" | bc)
                echo "$N,$i,$latency" >> "$LOCK_LOG"

                # Small delay to avoid thundering herd
                sleep 0.1
            done
        ) &
        pids+=($!)
    done

    # Wait for all workers to complete
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local elapsed=$(echo "$(date +%s.%N) - $start_time" | bc)
    echo "[measure] N=$N completed in ${elapsed}s"
}

# Run the spike at different concurrency levels
echo "=== FLEET-033 SQLite Contention Spike ==="
echo ""

for N in 10 30; do
    measure_contention "$N" 10
    echo ""
done

# Analyze results
if [ -s "$LOCK_LOG" ]; then
    echo "=== Contention Analysis ==="
    echo ""

    # Per-N latency statistics
    for N in 10 30; do
        p50=$(grep "^$N," "$LOCK_LOG" | awk -F, '{print $3}' | sort -n | awk 'NR==int(0.5*NR);END{print}')
        p95=$(grep "^$N," "$LOCK_LOG" | awk -F, '{print $3}' | sort -n | awk 'NR==int(0.95*NR);END{print}')
        p99=$(grep "^$N," "$LOCK_LOG" | awk -F, '{print $3}' | sort -n | tail -1)
        avg=$(grep "^$N," "$LOCK_LOG" | awk -F, '{sum+=$3; count++} END{print sum/count}')

        echo "N=$N:"
        echo "  p50: ${p50:-N/A}s"
        echo "  p95: ${p95:-N/A}s"
        echo "  p99: ${p99:-N/A}s"
        echo "  avg: ${avg:-N/A}s"
        echo ""
    done
else
    echo "No contention data collected"
fi

echo "Raw data: $LOCK_LOG"
echo "Spike dir: $SPIKE_DIR"
