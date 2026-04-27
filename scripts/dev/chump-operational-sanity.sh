#!/usr/bin/env bash
# Machine-runnable strip: health + stack-status (+ optional preflight) while chump --web is up.
# No human judgment — use after ./run-web.sh or in cron against a known base URL.
# Exit 0 on success; non-zero if curls fail or optional preflight fails.
#
# Env:
#   CHUMP_E2E_BASE_URL / CHUMP_PREFLIGHT_BASE_URL — default http://127.0.0.1:3000
#   CHUMP_OPERATIONAL_SKIP_PREFLIGHT=1 — skip chump --preflight (e.g. CI without full .env)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/chump-web-base.sh
source "$ROOT/scripts/lib/chump-web-base.sh"

BASE="${CHUMP_E2E_BASE_URL:-${CHUMP_PREFLIGHT_BASE_URL:-http://127.0.0.1:3000}}"
BASE="${BASE%/}"
export CHUMP_PREFLIGHT_BASE_URL="$BASE"

echo "== chump-operational-sanity: BASE=$BASE =="

if ! chump_web_health_ok "$BASE"; then
  echo "FAIL: web health not OK at $BASE (start ./run-web.sh or set CHUMP_E2E_BASE_URL)" >&2
  exit 1
fi

code_h="$(curl -sS -o /tmp/chump-sanity-health.json -w '%{http_code}' --max-time 15 "${BASE}/api/health" || echo 000)"
if [[ "$code_h" != "200" ]]; then
  echo "FAIL: GET /api/health HTTP $code_h" >&2
  exit 1
fi
echo "OK: GET /api/health"

code_s="$(curl -sS -o /tmp/chump-sanity-stack.json -w '%{http_code}' --max-time 20 "${BASE}/api/stack-status" || echo 000)"
if [[ "$code_s" != "200" ]]; then
  echo "FAIL: GET /api/stack-status HTTP $code_s" >&2
  exit 1
fi
if ! grep -q '"tool_policy"' /tmp/chump-sanity-stack.json; then
  echo "FAIL: stack-status JSON missing tool_policy" >&2
  exit 1
fi
echo "OK: GET /api/stack-status (tool_policy present)"

if [[ "${CHUMP_OPERATIONAL_SKIP_PREFLIGHT:-0}" == "1" ]]; then
  echo "Skip: CHUMP_OPERATIONAL_SKIP_PREFLIGHT=1 (preflight not run)"
  exit 0
fi

BIN="$ROOT/target/release/chump"
if [[ ! -x "$BIN" ]]; then
  BIN="$ROOT/target/debug/chump"
fi
if [[ ! -x "$BIN" ]]; then
  echo "WARN: no built chump binary — skipping --preflight (cargo build --bin chump)" >&2
  exit 0
fi

echo "Running: $BIN --preflight …"
if ! "$BIN" --preflight; then
  echo "FAIL: chump --preflight" >&2
  exit 1
fi
echo "OK: chump --preflight"
exit 0
