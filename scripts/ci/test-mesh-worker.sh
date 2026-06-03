#!/usr/bin/env bash
# scripts/ci/test-mesh-worker.sh — INFRA-2545
# The FLEET-034 work-routing CONSUMER must be fail-open, bounded, route-only by
# default, and bridge to the standard executor only on explicit opt-in.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
S=scripts/coord/mesh-worker-loop.sh
PL=scripts/setup/com.chump.mesh-worker.plist
REG=docs/observability/EVENT_REGISTRY.yaml
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-mesh-worker.sh (INFRA-2545) ==="
{ [ -f "$S" ] && [ -x "$S" ]; } && p "loop script present + executable" || f "loop script missing/not-exec"
bash -n "$S" 2>/dev/null && p "loop script parses (bash -n)" || f "loop script SYNTAX ERROR"
{ grep -q 'ping' "$S" && grep -qiE 'fail-open|exit 0' "$S"; } 2>/dev/null \
  && p "fail-open when broker unreachable" || f "no fail-open"
grep -q 'CHUMP_MESH_WORKER_EXECUTE' "$S" 2>/dev/null \
  && p "route-only default + execute opt-in" || f "no execute gate"
grep -q 'worker --once' "$S" 2>/dev/null \
  && p "bounded: one gap per tick (--once)" || f "not bounded"
grep -q 'chump --execute-gap' "$S" 2>/dev/null \
  && p "execute mode bridges to chump --execute-gap" || f "no executor bridge"
grep -q 'release' "$S" 2>/dev/null \
  && p "releases the NATS-KV routing-claim (no dual-claim conflict)" || f "no claim release"
{ grep -q 'mesh_worker_routed' "$REG" && grep -q 'mesh_worker_executing' "$REG"; } 2>/dev/null \
  && p "both events registered in EVENT_REGISTRY" || f "events not registered"

# plist: present, conservative cadence, NOT KeepAlive, route-only default
[ -f "$PL" ] && p "plist template present" || f "no plist template"
{ grep -q 'StartInterval' "$PL" && ! grep -q 'KeepAlive' "$PL"; } 2>/dev/null \
  && p "conservative cadence (StartInterval, not KeepAlive)" || f "plist cadence wrong"
grep -A1 'CHUMP_MESH_WORKER_EXECUTE' "$PL" 2>/dev/null | grep -q '<string>0</string>' \
  && p "plist defaults to route-only (EXECUTE=0)" || f "plist not route-only by default"

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
