#!/usr/bin/env bash
# scripts/ci/test-jetstream-consumer-roundtrip.sh — META-175
#
# Smoke test: start ephemeral NATS, publish 5 events, consumer drains + acks
# all 5, assert no replay on clean restart.
#
# Requires:
#   - nats-server on PATH (brew install nats-server / apt-get install nats-server)
#   - cargo (Rust toolchain)
#   - CHUMP_FLEET_WIRE_V1=1 set (or passed as env)
#
# When nats-server is not on PATH the test SKIPs with exit 0 so CI does not
# red-flag environments without NATS (same skip behaviour as the Rust integration
# tests).
#
# Usage:
#   bash scripts/ci/test-jetstream-consumer-roundtrip.sh
#   CHUMP_FLEET_WIRE_V1=1 bash scripts/ci/test-jetstream-consumer-roundtrip.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NATS_PORT=${CHUMP_TEST_NATS_PORT:-14522}
NATS_URL="nats://127.0.0.1:${NATS_PORT}"
NATS_PID=""

log() { printf '[test-jetstream-consumer-roundtrip] %s\n' "$*" >&2; }
skip() { log "SKIP — $*"; exit 0; }
fail() { log "FAIL — $*"; exit 1; }

cleanup() {
  if [[ -n "${NATS_PID}" ]]; then
    kill "${NATS_PID}" 2>/dev/null || true
    wait "${NATS_PID}" 2>/dev/null || true
    log "stopped ephemeral nats-server (pid=${NATS_PID})"
  fi
}
trap cleanup EXIT

# ── Prereq checks ─────────────────────────────────────────────────────────────

if ! command -v nats-server &>/dev/null; then
  skip "nats-server not on PATH (install: brew install nats-server)"
fi

if ! command -v cargo &>/dev/null; then
  skip "cargo not on PATH"
fi

# ── Start ephemeral NATS with JetStream ───────────────────────────────────────

log "starting ephemeral nats-server on port ${NATS_PORT}"
nats-server -p "${NATS_PORT}" -js &
NATS_PID=$!

# Wait up to 3s for it to be ready.
for i in $(seq 1 15); do
  if nats-server --help &>/dev/null 2>&1; then : ; fi
  if nc -z 127.0.0.1 "${NATS_PORT}" 2>/dev/null; then
    log "nats-server ready (attempt ${i})"
    break
  fi
  sleep 0.2
  if [[ $i -eq 15 ]]; then
    fail "nats-server did not start on port ${NATS_PORT} within 3s"
  fi
done

# ── Run Rust integration tests with live NATS ─────────────────────────────────

log "running cargo test (ignored) for chump-coord jetstream_replay..."

export CHUMP_FLEET_WIRE_V1=1
export CHUMP_NATS_URL="${NATS_URL}"
export CHUMP_NATS_TIMEOUT_MS=2000
export CHUMP_FLEET_WIRE_FETCH_TIMEOUT_MS=500

# Run only the ignored jetstream_replay tests (requires live NATS).
# --ignored runs tests marked #[ignore]; the roundtrip + no-replay checks live there.
cd "${REPO_ROOT}"
if cargo test \
    -p chump-coord \
    --test jetstream_replay \
    -- --ignored --nocapture 2>&1; then
  log "jetstream_replay tests PASSED"
else
  fail "jetstream_replay tests FAILED"
fi

# ── Additional roundtrip check via nats CLI (if available) ───────────────────
# Publish 5 raw events and verify the stream has at least 5 messages.
if command -v nats &>/dev/null; then
  log "verifying stream message count via nats CLI"
  for i in $(seq 1 5); do
    nats -s "${NATS_URL}" pub "chump.events.intent" \
      "{\"event\":\"INTENT\",\"session\":\"ci-smoke-${i}\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
      2>/dev/null || true
  done
  sleep 0.5
  MSG_COUNT=$(nats -s "${NATS_URL}" stream info CHUMP_EVENTS --json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state']['messages'])" 2>/dev/null || echo 0)
  log "stream message count: ${MSG_COUNT}"
  if [[ "${MSG_COUNT}" -ge 5 ]]; then
    log "stream count check PASSED (${MSG_COUNT} >= 5)"
  else
    log "WARN: stream count ${MSG_COUNT} < 5 (nats CLI publish may have failed — non-blocking)"
  fi
else
  log "nats CLI not on PATH — skipping stream count verification (non-blocking)"
fi

log "PASS"
