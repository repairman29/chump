#!/usr/bin/env bash
# scripts/ci/test-curator-supervisor.sh — INFRA-2239
#
# Smoke test for chump-curator-supervisor.
# Sets up fixture files (synth log + stale ambient heartbeat), runs the
# supervisor in DRY_RUN mode, asserts correct ambient events, then verifies
# sentinel dedup suppresses re-filing on a second run.
#
# Exit 0 = PASS, non-zero = FAIL.
#
# Usage:
#   bash scripts/ci/test-curator-supervisor.sh
#   CHUMP_CURATOR_SUPERVISOR_BIN=/path/to/bin bash scripts/ci/test-curator-supervisor.sh

set -euo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo /Users/jeffadkins/Projects/Chump)}"
BIN="${CHUMP_CURATOR_SUPERVISOR_BIN:-}"

# ── resolve binary ─────────────────────────────────────────────────────────
if [[ -z "$BIN" ]]; then
    RELEASE_BIN="$REPO_ROOT/target/release/chump-curator-supervisor"
    DEBUG_BIN="$REPO_ROOT/target/debug/chump-curator-supervisor"
    if [[ -f "$RELEASE_BIN" ]]; then
        BIN="$RELEASE_BIN"
    elif [[ -f "$DEBUG_BIN" ]]; then
        BIN="$DEBUG_BIN"
    else
        echo "[test-curator-supervisor] Building debug binary..."
        (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
            cargo build -p chump-curator-supervisor 2>&1) || {
            echo "[test-curator-supervisor] FAIL: cargo build failed"
            exit 1
        }
        BIN="$DEBUG_BIN"
    fi
fi

if [[ ! -x "$BIN" ]]; then
    echo "[test-curator-supervisor] FAIL: binary not executable at $BIN"
    exit 1
fi

echo "[test-curator-supervisor] using binary: $BIN"

# ── temp fixture environment ───────────────────────────────────────────────
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

LOG_DIR="$TMPDIR_FIXTURE/autopilot-logs"
AMBIENT="$TMPDIR_FIXTURE/ambient.jsonl"
SENTINEL_DIR="$TMPDIR_FIXTURE/curator-supervisor/seen"
mkdir -p "$LOG_DIR" "$SENTINEL_DIR"

# ── fixture: broken decompose log ─────────────────────────────────────────
# Write a synth curator-decompose.log with "unknown subcommand: tick" lines.
DECOMPOSE_LOG="$LOG_DIR/curator-decompose.log"
for i in $(seq 1 10); do
    echo "[$i] error: unknown subcommand: tick" >> "$DECOMPOSE_LOG"
done
for i in $(seq 1 5); do
    echo "[$i] normal output line" >> "$DECOMPOSE_LOG"
done
for i in $(seq 1 10); do
    echo "[$i] error: unknown subcommand: heartbeat" >> "$DECOMPOSE_LOG"
done
echo "[test-curator-supervisor] wrote synth decompose log (20 error lines, 5 normal)"

# ── fixture: stale heartbeat in ambient.jsonl ──────────────────────────────
# Write a curator_heartbeat for decompose that is 30 minutes old (> 10-min stall threshold).
STALE_TS=$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
           date -u --date='30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
           python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
printf '{"ts":"%s","kind":"curator_heartbeat","role":"decompose","session":"curator-opus-decompose-2026-05-30"}\n' \
    "$STALE_TS" >> "$AMBIENT"
echo "[test-curator-supervisor] wrote stale heartbeat ts=$STALE_TS"

# ── run 1: supervisor dry-run — expect gap-filed + respawn events ──────────
echo ""
echo "[test-curator-supervisor] === RUN 1: expect detection + would-file-gap + would-respawn-pane ==="

CHUMP_CURATOR_SUPERVISOR_DRY_RUN=1 \
CHUMP_CURATOR_SUPERVISOR_MODE=aggressive \
CHUMP_CURATOR_SUPERVISOR_AUTORESTART=1 \
CHUMP_CURATOR_SUPERVISOR_LOG_DIR="$LOG_DIR" \
CHUMP_CURATOR_SUPERVISOR_AMBIENT="$AMBIENT" \
CHUMP_CURATOR_SUPERVISOR_SENTINEL_DIR="$SENTINEL_DIR" \
CHUMP_CURATOR_HEARTBEAT_STALL_M=10 \
CHUMP_CURATOR_SUPERVISOR_SENTINEL_TTL_H=24 \
CHUMP_REPO_ROOT="$REPO_ROOT" \
RUST_LOG=info \
    "$BIN" 2>&1 || true   # supervisor exits 0 even on detected failures

# Assert: at least one curator_supervisor_dry_run event was emitted.
FILED_COUNT=$(grep -c '"action":"would-file-gap"' "$AMBIENT" 2>/dev/null || echo 0)
RESPAWN_COUNT=$(grep -c '"action":"would-respawn-pane"' "$AMBIENT" 2>/dev/null || echo 0)
SONNET_COUNT=$(grep -c '"action":"would-spawn-sonnet"' "$AMBIENT" 2>/dev/null || echo 0)

echo "[test-curator-supervisor] would-file-gap events:    $FILED_COUNT"
echo "[test-curator-supervisor] would-respawn-pane events: $RESPAWN_COUNT"
echo "[test-curator-supervisor] would-spawn-sonnet events: $SONNET_COUNT"

FAILED=0

if [[ "$FILED_COUNT" -lt 1 ]]; then
    echo "[test-curator-supervisor] FAIL: expected >=1 would-file-gap event, got $FILED_COUNT"
    FAILED=1
fi

if [[ "$RESPAWN_COUNT" -lt 1 ]]; then
    echo "[test-curator-supervisor] FAIL: expected >=1 would-respawn-pane event, got $RESPAWN_COUNT"
    FAILED=1
fi

if [[ "$SONNET_COUNT" -lt 1 ]]; then
    echo "[test-curator-supervisor] FAIL: expected >=1 would-spawn-sonnet event in Aggressive default mode, got $SONNET_COUNT"
    FAILED=1
fi

# Assert: sentinel file was created for decompose role.
SENTINEL_COUNT=$(find "$SENTINEL_DIR" -name "decompose:*.sentinel" 2>/dev/null | wc -l | tr -d ' ')
echo "[test-curator-supervisor] sentinel files for decompose: $SENTINEL_COUNT"
if [[ "$SENTINEL_COUNT" -lt 1 ]]; then
    echo "[test-curator-supervisor] FAIL: expected sentinel file for decompose, found none"
    FAILED=1
fi

# ── run 2: same fixture — sentinel must suppress re-filing ─────────────────
echo ""
echo "[test-curator-supervisor] === RUN 2: expect sentinel dedup (no new would-file-gap) ==="

AMBIENT_LINES_BEFORE=$(wc -l < "$AMBIENT" | tr -d ' ')

CHUMP_CURATOR_SUPERVISOR_DRY_RUN=1 \
CHUMP_CURATOR_SUPERVISOR_MODE=aggressive \
CHUMP_CURATOR_SUPERVISOR_AUTORESTART=1 \
CHUMP_CURATOR_SUPERVISOR_LOG_DIR="$LOG_DIR" \
CHUMP_CURATOR_SUPERVISOR_AMBIENT="$AMBIENT" \
CHUMP_CURATOR_SUPERVISOR_SENTINEL_DIR="$SENTINEL_DIR" \
CHUMP_CURATOR_HEARTBEAT_STALL_M=10 \
CHUMP_CURATOR_SUPERVISOR_SENTINEL_TTL_H=24 \
CHUMP_REPO_ROOT="$REPO_ROOT" \
RUST_LOG=info \
    "$BIN" 2>&1 || true

AMBIENT_LINES_AFTER=$(wc -l < "$AMBIENT" | tr -d ' ')
NEW_LINES=$(( AMBIENT_LINES_AFTER - AMBIENT_LINES_BEFORE ))
NEW_FILED=$(grep '"action":"would-file-gap"' "$AMBIENT" 2>/dev/null | tail -"$NEW_LINES" | wc -l | tr -d ' ' || echo 0)

echo "[test-curator-supervisor] new ambient lines in run 2: $NEW_LINES"
echo "[test-curator-supervisor] new would-file-gap in run 2: $NEW_FILED"

if [[ "$NEW_FILED" -gt 0 ]]; then
    echo "[test-curator-supervisor] FAIL: sentinel dedup failed — would-file-gap fired again in run 2"
    FAILED=1
fi

# ── RESILIENT-035 circuit breaker test ─────────────────────────────────────
# Seed 3 activation sentinels for decompose (max_spawns_per_hour=3 default →
# 4th detection must trip the breaker). Use a DIFFERENT fingerprint each
# time to bypass the existing sentinel dedup.
echo ""
echo "[test-curator-supervisor] === RUN 3: expect circuit-breaker trip on 4th activation ==="
ACTIVATION_DIR="$SENTINEL_DIR/../activations/decompose"
mkdir -p "$ACTIVATION_DIR"
for i in 1 2 3; do
    touch "$ACTIVATION_DIR/marker_$i.act"
done

# Clear sentinel dedup so the supervisor reaches the spawn/restart phase
# again, and rewrite the log with a NEW error pattern so we get a fresh
# fingerprint (otherwise dedup catches it before the breaker).
rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
{
  for i in 1 2 3 4 5 6; do
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] error: fresh-pattern-for-circuit-test-iteration-$i"
  done
} > "$LOG_DIR/curator-decompose.log"

# Snapshot ambient before run 3.
PRE_RUN3_LINES=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)

CHUMP_CURATOR_SUPERVISOR_LOG_DIR="$LOG_DIR" \
  CHUMP_CURATOR_SUPERVISOR_AMBIENT="$AMBIENT" \
  CHUMP_CURATOR_SUPERVISOR_SENTINEL_DIR="$SENTINEL_DIR" \
  CHUMP_CURATOR_SUPERVISOR_MODE=aggressive \
  CHUMP_CURATOR_SUPERVISOR_AUTORESTART=1 \
  CHUMP_CURATOR_SUPERVISOR_DRY_RUN=1 \
  "$BIN"

BREAKER_COUNT=$(tail -n +$((PRE_RUN3_LINES + 1)) "$AMBIENT" 2>/dev/null \
    | grep -c '"kind":"curator_supervisor_circuit_broken"' || echo 0)
NEW_SPAWN_COUNT=$(tail -n +$((PRE_RUN3_LINES + 1)) "$AMBIENT" 2>/dev/null \
    | grep -c '"action":"would-spawn-sonnet"' || echo 0)

echo "[test-curator-supervisor] curator_supervisor_circuit_broken events in run 3: $BREAKER_COUNT"
echo "[test-curator-supervisor] would-spawn-sonnet events in run 3: $NEW_SPAWN_COUNT"

if [[ "$BREAKER_COUNT" -lt 1 ]]; then
    echo "[test-curator-supervisor] FAIL: expected >=1 curator_supervisor_circuit_broken event after 3 prior activations, got $BREAKER_COUNT"
    FAILED=1
fi
if [[ "$NEW_SPAWN_COUNT" -gt 0 ]]; then
    echo "[test-curator-supervisor] FAIL: circuit broken but would-spawn-sonnet still fired ($NEW_SPAWN_COUNT times) — breaker did not halt remediation"
    FAILED=1
fi

# ── result ──────────────────────────────────────────────────────────────────
echo ""
if [[ "$FAILED" -eq 0 ]]; then
    echo "[test-curator-supervisor] PASS"
    exit 0
else
    echo "[test-curator-supervisor] FAIL (see above)"
    echo "--- ambient.jsonl contents ---"
    cat "$AMBIENT" || true
    exit 1
fi
