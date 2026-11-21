#!/usr/bin/env bash
# test-worker-doctor-preflight.sh — INFRA-333.
#
# Asserts that scripts/dispatch/worker.sh runs scripts/dev/chump-binary-unwedge.sh
# as the first action of its session-start phase, BEFORE any `chump gap`
# invocation. This pre-empts the INFRA-275 wedged-inode hang where
# `chump gap list` would otherwise hang indefinitely at _dyld_start.
#
# Strategy: spawn worker.sh in a tempdir with a synthetic REPO_ROOT
# whose `scripts/dev/chump-binary-unwedge.sh` and a PATH-shadowed `chump` binary
# both append a line to an order log. After ~3s, kill worker.sh and
# read the log: `doctor` must appear before `chump-gap`.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

if [ ! -f "$WORKER" ]; then
    echo "FAIL: $WORKER not found" >&2
    exit 1
fi

echo "[1] bash syntax check on worker.sh"
bash -n "$WORKER"
echo "    OK"

echo "[2] order test: doctor runs before any 'chump gap' call"
TMPROOT=$(mktemp -d -t worker-doctor-test.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# Lay out the synthetic REPO_ROOT.
mkdir -p "$TMPROOT/scripts/dev"
mkdir -p "$TMPROOT/scripts/dispatch"
mkdir -p "$TMPROOT/scripts/coord"
mkdir -p "$TMPROOT/.chump-locks"
mkdir -p "$TMPROOT/binstub"
ORDER_LOG="$TMPROOT/order.log"
: > "$ORDER_LOG"

# Mock chump-binary-unwedge.sh — logs "doctor" with a unix-ms timestamp, exits 0
# fast (the real one probes in <5s when healthy).
cat > "$TMPROOT/scripts/dev/chump-binary-unwedge.sh" <<EOF
#!/usr/bin/env bash
printf 'doctor %s\n' "\$(date +%s%N)" >> "$ORDER_LOG"
exit 0
EOF
chmod +x "$TMPROOT/scripts/dev/chump-binary-unwedge.sh"

# Mock chump on PATH — logs "chump-gap <args>" then sleeps. The worker's
# first chump call is `chump gap list --status open --json` early in the
# loop body. Sleeping keeps the worker in that call until we kill it,
# guaranteeing only ONE chump-gap entry appears (clean ordering check).
cat > "$TMPROOT/binstub/chump" <<EOF
#!/usr/bin/env bash
printf 'chump-gap %s\n' "\$*" >> "$ORDER_LOG"
sleep 30
EOF
chmod +x "$TMPROOT/binstub/chump"

# Copy worker.sh into the tempdir so REPO_ROOT discovery resolves there.
cp "$WORKER" "$TMPROOT/scripts/dispatch/worker.sh"

# Stub out _pick_gap.py — never invoked because we kill before the
# python pick step, but worker.sh references the path. Make it harmless.
cat > "$TMPROOT/scripts/dispatch/_pick_gap.py" <<'EOF'
import sys
sys.exit(0)
EOF

# Run worker.sh in the background with mocked PATH and REPO_ROOT.
# IDLE_SLEEP_S=1 so the loop iterates fast if it gets past `chump gap list`.
PATH="$TMPROOT/binstub:$PATH" \
    REPO_ROOT="$TMPROOT" \
    AGENT_ID="test" \
    FLEET_LOG_DIR="$TMPROOT/logs" \
    IDLE_SLEEP_S=1 \
    FLEET_TIMEOUT_S=10 \
    bash "$TMPROOT/scripts/dispatch/worker.sh" >"$TMPROOT/worker.out" 2>"$TMPROOT/worker.err" &
WORKER_PID=$!

# Give the worker time to: run doctor, then enter loop, then call chump gap.
sleep 3

# Kill the worker and any chump stub it spawned.
kill -TERM "$WORKER_PID" 2>/dev/null || true
sleep 0.5
kill -KILL "$WORKER_PID" 2>/dev/null || true
pkill -KILL -f "$TMPROOT/binstub/chump" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true

# Inspect the order log.
if [ ! -s "$ORDER_LOG" ]; then
    echo "    FAIL: order log empty — worker did not execute doctor or chump" >&2
    echo "--- worker.out ---" >&2
    cat "$TMPROOT/worker.out" >&2 || true
    echo "--- worker.err ---" >&2
    cat "$TMPROOT/worker.err" >&2 || true
    exit 1
fi

DOCTOR_LINE=$(grep -n '^doctor ' "$ORDER_LOG" | head -1 | cut -d: -f1 || true)
CHUMP_LINE=$(grep -n '^chump-gap ' "$ORDER_LOG" | head -1 | cut -d: -f1 || true)

if [ -z "$DOCTOR_LINE" ]; then
    echo "    FAIL: doctor was never invoked by worker.sh" >&2
    echo "--- order log ---" >&2
    cat "$ORDER_LOG" >&2
    exit 1
fi

if [ -n "$CHUMP_LINE" ] && [ "$DOCTOR_LINE" -gt "$CHUMP_LINE" ]; then
    echo "    FAIL: chump gap was invoked BEFORE chump-binary-unwedge.sh" >&2
    echo "    doctor at line $DOCTOR_LINE, chump-gap at line $CHUMP_LINE" >&2
    echo "--- order log ---" >&2
    cat "$ORDER_LOG" >&2
    exit 1
fi

echo "    OK (doctor at line $DOCTOR_LINE; chump-gap first seen at line ${CHUMP_LINE:-N/A})"

echo "[3] healthy-binary overhead < 6s"
# Re-run with the same mocks; measure wall-clock from start to first
# chump-gap log entry. If the doctor is healthy (our mock exits in ms),
# the worker should reach `chump gap list` quickly — well under the
# 6s budget the gap acceptance criteria require.
: > "$ORDER_LOG"
START_NS=$(date +%s%N)
PATH="$TMPROOT/binstub:$PATH" \
    REPO_ROOT="$TMPROOT" \
    AGENT_ID="test" \
    FLEET_LOG_DIR="$TMPROOT/logs" \
    IDLE_SLEEP_S=1 \
    FLEET_TIMEOUT_S=10 \
    bash "$TMPROOT/scripts/dispatch/worker.sh" >"$TMPROOT/worker.out" 2>"$TMPROOT/worker.err" &
WORKER_PID=$!

# Poll for the first chump-gap line, capped at 6s.
for _ in $(seq 1 60); do
    if grep -q '^chump-gap ' "$ORDER_LOG" 2>/dev/null; then
        END_NS=$(date +%s%N)
        break
    fi
    sleep 0.1
done

kill -TERM "$WORKER_PID" 2>/dev/null || true
sleep 0.3
kill -KILL "$WORKER_PID" 2>/dev/null || true
pkill -KILL -f "$TMPROOT/binstub/chump" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true

if [ -z "${END_NS:-}" ]; then
    echo "    FAIL: worker did not reach 'chump gap' within 6s" >&2
    cat "$ORDER_LOG" >&2
    exit 1
fi

ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
if [ "$ELAPSED_MS" -gt 6000 ]; then
    echo "    FAIL: start-up overhead ${ELAPSED_MS}ms > 6000ms budget" >&2
    exit 1
fi
echo "    OK (start-up to first chump gap: ${ELAPSED_MS}ms < 6000ms)"

echo
echo "[smoke] all checks passed."
