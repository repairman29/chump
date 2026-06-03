#!/usr/bin/env bash
# scripts/ci/test-bot-merge-mode-failopen.sh — INFRA-2523
#
# bot-merge must NOT route a gap to the batched integrator (Mode A) when the
# integrator daemon is unhealthy — it must fail OPEN to per-PR auto-merge
# (Mode B) so no gap lands in dead-queue limbo (the INFRA-2455 / INFRA-1120 /
# INFRA-2188 ghost class). The existing fallback only checked NATS availability;
# NATS-up != integrator-alive, so a dead-binary daemon still got Mode A.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
BM=scripts/coord/bot-merge.sh
REG=docs/observability/EVENT_REGISTRY.yaml
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-bot-merge-mode-failopen.sh (INFRA-2523) ==="

bash -n "$BM" 2>/dev/null && p "bot-merge.sh parses (bash -n)" || f "bot-merge.sh SYNTAX ERROR"

# ── Structural: the fail-open wiring is present ──────────────────────────────
grep -q '_bm_integrator_healthy' "$BM" 2>/dev/null \
  && p "integrator-health helper present" || f "no _bm_integrator_healthy"
grep -q 'fail-open to per-PR (INFRA-2523)' "$BM" 2>/dev/null \
  && p "Mode A + unhealthy -> fail-open to Mode B (reason wired)" || f "fail-open redirect missing"
grep -q 'CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH' "$BM" 2>/dev/null \
  && p "test mock hook present" || f "no mock hook"
grep -q 'kind: bot_merge_mode_failopen' "$REG" 2>/dev/null \
  && p "bot_merge_mode_failopen registered in EVENT_REGISTRY" || f "event NOT registered"

# ── Bounded: the health probe must not block on network/sleep ────────────────
fn="$(sed -n '/^_bm_integrator_healthy() {/,/^}/p' "$BM")"
if [ -z "$fn" ]; then
  f "could not extract _bm_integrator_healthy()"
elif printf '%s' "$fn" | grep -qE 'curl|wget|nc |sleep|gh api'; then
  f "health probe not bounded (network/sleep present)"
else
  p "health probe is bounded (no network/sleep)"
fi

# ── Functional: extract the REAL helper + assert the mock contract ───────────
if [ -n "$fn" ]; then
  ( eval "$fn"; _BM_INTEGRATOR_HEALTHY_CACHE=""; CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH=1 _bm_integrator_healthy ) && h=0 || h=1
  ( eval "$fn"; _BM_INTEGRATOR_HEALTHY_CACHE=""; CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH=0 _bm_integrator_healthy ) && u=0 || u=1
  if [ "$h" = 0 ] && [ "$u" = 1 ]; then
    p "mock contract holds: healthy->rc0, unhealthy->rc1 (h=$h u=$u)"
  else
    f "mock contract wrong (expected h=0 u=1; got h=$h u=$u)"
  fi
fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
