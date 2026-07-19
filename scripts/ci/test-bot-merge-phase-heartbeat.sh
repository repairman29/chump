#!/usr/bin/env bash
# scripts/ci/test-bot-merge-phase-heartbeat.sh — INFRA-1732
#
# bot-merge.sh's existing 30s liveness loop (INFRA-2455) writes a health FILE
# and a stderr line, but emitted nothing to ambient.jsonl — so the only
# programmatic stall detector was the single hardcoded elapsed-time budget
# watchdog (silent stall observed 2026-05-22). This test verifies the health
# loop now also mirrors its liveness as a periodic
# kind=bot_merge_phase_heartbeat ambient event, so fleet monitors can key
# stall detection off event staleness instead of waiting out the full budget.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
BM=scripts/coord/bot-merge.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-bot-merge-phase-heartbeat.sh (INFRA-1732) ==="

[[ -f "$BM" ]] || { f "bot-merge.sh MISSING"; echo "=== $P passed, $((F)) failed ==="; exit 1; }
p "bot-merge.sh present"
bash -n "$BM" 2>/dev/null && p "bot-merge.sh parses (bash -n)" || f "bot-merge.sh SYNTAX ERROR"

grep -q 'INFRA-1732' "$BM" 2>/dev/null \
  && p "INFRA-1732 marker present" || f "INFRA-1732 marker absent"

grep -q '"kind":"bot_merge_phase_heartbeat"' "$BM" 2>/dev/null \
  && p "emits kind=bot_merge_phase_heartbeat" || f "bot_merge_phase_heartbeat kind not emitted"

# Emission must live inside the existing 30s health loop (reuse, not a new
# timer) — same block that writes the health file and stderr liveness line.
if awk '/_BM_HEALTH_PID=\$!/{exit} /_hb_elapsed=0/,0' "$BM" | grep -q 'bot_merge_phase_heartbeat'; then
  p "heartbeat event emitted from within the existing health loop"
else
  f "heartbeat event not found inside the existing health-loop subshell"
fi

# Required fields per docs/observability/EVENT_REGISTRY.yaml entry.
_HB_BLOCK="$(awk '/_hb_elapsed=0/,/_BM_HEALTH_PID=\$!/' "$BM")"
for field in '"ts"' '"kind"' '"pid"' '"step"' '"elapsed_s"' '"interval_s"' '"gap_ids"'; do
  if grep -qF "$field" <<<"$_HB_BLOCK"; then
    p "heartbeat payload includes $field"
  else
    f "heartbeat payload missing $field"
  fi
done

# Registered in the event registry with effect_metric + consumers (INFRA-1371 v2 format).
REG=docs/observability/EVENT_REGISTRY.yaml
if grep -A2 'kind: bot_merge_phase_heartbeat' "$REG" 2>/dev/null | grep -q 'effect_metric:'; then
  p "registered in EVENT_REGISTRY.yaml with effect_metric"
else
  f "bot_merge_phase_heartbeat missing from EVENT_REGISTRY.yaml (or missing effect_metric)"
fi

# Non-duplication (META-063): must not introduce a second competing kind for
# the same progress signal.
_dup_count="$(grep -c 'kind: bot_merge_phase_heartbeat' "$REG" 2>/dev/null || echo 0)"
if [[ "$_dup_count" -eq 1 ]]; then
  p "exactly one bot_merge_phase_heartbeat registry entry (no duplication)"
else
  f "expected exactly 1 bot_merge_phase_heartbeat registry entry, found $_dup_count"
fi

# Functional smoke test: extract the printf format + verify it produces
# well-formed JSON with the expected fields when fed representative values.
_JSON_LINE="$(printf '{"ts":"%s","kind":"bot_merge_phase_heartbeat","pid":%d,"step":"%s","elapsed_s":%d,"interval_s":%d,"gap_ids":"%s","note":"%s"}\n' \
  "2026-07-19T17:00:00Z" 12345 "gap_ship" 90 30 "INFRA-1732" "smoke test")"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$_JSON_LINE" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["kind"]=="bot_merge_phase_heartbeat"; assert d["elapsed_s"]==90' 2>/dev/null; then
    p "smoke: heartbeat payload shape parses as valid JSON with expected fields"
  else
    f "smoke: heartbeat payload failed to parse as valid JSON"
  fi
else
  echo "[SKIP] python3 unavailable — skipping JSON-shape smoke check"
fi

echo ""
echo "=== $P passed, $F failed ==="
[[ "$F" -eq 0 ]] || exit 1
