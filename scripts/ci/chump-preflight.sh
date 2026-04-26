#!/usr/bin/env bash
# Unified preflight for daily-driver / universal-power P1.
# Requires chump --web (or ./run-web.sh) already listening.
#
# Checks: GET /api/health, GET /api/stack-status (status, inference, tool_policy),
# optional Bearer when CHUMP_WEB_TOKEN is set, logs/ writable under repo root.
#
# Usage (repo root):
#   ./scripts/ci/chump-preflight.sh
#   CHUMP_E2E_BASE_URL=http://127.0.0.1:3847 ./scripts/ci/chump-preflight.sh
#   ./scripts/ci/chump-preflight.sh --warn-only       # degraded local inference → WARN, still exit 0
#
# See docs/operations/OPERATIONS.md "Preflight", docs/strategy/ROADMAP_UNIVERSAL_POWER.md P1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"

WARN_ONLY=0
for a in "$@"; do
  case "$a" in
    --warn-only) WARN_ONLY=1 ;;
  esac
done

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

echo "== chump-preflight: repo=$ROOT =="

LOGS="$ROOT/logs"
mkdir -p "$LOGS"
_tmp="$LOGS/.preflight-write-test.$$"
if ! (umask 022 && : >"$_tmp"); then
  echo "FAIL: cannot write to $LOGS (create logs/ and check permissions)."
  exit 1
fi
rm -f "$_tmp"
echo "OK: logs directory writable ($LOGS)"

# shellcheck source=scripts/lib/chump-web-base.sh
source "$ROOT/scripts/lib/chump-web-base.sh"

BASE="${CHUMP_PREFLIGHT_BASE_URL:-${CHUMP_E2E_BASE_URL:-}}"
if [[ -z "$BASE" ]]; then
  BASE="$(chump_resolve_e2e_base_url)"
fi
BASE="${BASE%/}"
echo "Probing Chump web at: $BASE"

if ! chump_web_health_ok "$BASE"; then
  echo "FAIL: GET $BASE/api/health did not return chump-web JSON."
  echo "Fix: start the web server — ./run-web.sh or CHUMP_WEB_PORT=3000 ./target/debug/chump --web"
  echo "Docs: docs/process/EXTERNAL_GOLDEN_PATH.md"
  exit 1
fi
echo "OK: /api/health (chump-web)"

STACK_JSON="$(mktemp "${TMPDIR:-/tmp}/chump-stack.XXXXXX.json")"
cleanup() { rm -f "$STACK_JSON"; }
trap cleanup EXIT

CURL_AUTH=()
if [[ -n "${CHUMP_WEB_TOKEN:-}" ]]; then
  CURL_AUTH=(-H "Authorization: Bearer ${CHUMP_WEB_TOKEN}")
fi

code=$(curl -sS -o "$STACK_JSON" -w "%{http_code}" --max-time 20 "${CURL_AUTH[@]}" "$BASE/api/stack-status" || echo 000)
if [[ "$code" != "200" ]]; then
  echo "FAIL: GET /api/stack-status HTTP $code (token wrong? see CHUMP_WEB_TOKEN)"
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  st=$(jq -r '.status // empty' "$STACK_JSON")
  if [[ "$st" != "ok" ]]; then
    echo "FAIL: stack-status .status is not ok (got: ${st:-empty})"
    exit 1
  fi
  if ! jq -e '.tool_policy | type == "object"' "$STACK_JSON" >/dev/null 2>&1; then
    echo "FAIL: stack-status missing tool_policy object"
    exit 1
  fi
  if ! jq -e '.tool_policy.tools_ask | type == "array"' "$STACK_JSON" >/dev/null 2>&1; then
    echo "FAIL: stack-status tool_policy.tools_ask missing or not an array"
    exit 1
  fi
  primary=$(jq -r '.inference.primary_backend // empty' "$STACK_JSON")
  configured=$(jq -r '.inference.configured // empty' "$STACK_JSON")
  reachable=$(jq -r '.inference.models_reachable // empty' "$STACK_JSON")
  probe=$(jq -r '.inference.probe // empty' "$STACK_JSON")
  echo "OK: /api/stack-status (primary_backend=$primary probe=$probe configured=$configured models_reachable=$reachable)"

  if [[ "$primary" == "openai_compatible" && "$configured" == "true" && "$reachable" == "false" && "$probe" != "skipped_non_local" ]]; then
    err=$(jq -r '.inference.error // empty' "$STACK_JSON" | head -c 200)
    msg="Local OpenAI-compatible probe failed (models_reachable=false). Error: ${err:-unknown}"
    echo "FAIL: $msg"
    echo "Fix: start Ollama/MLX or set OPENAI_API_BASE; see docs/operations/INFERENCE_STABILITY.md and docs/operations/OPERATIONS.md"
    if [[ "$WARN_ONLY" == "1" ]]; then
      echo "(warn-only: exiting 0 anyway)"
      exit 0
    fi
    exit 1
  fi

  if [[ "$primary" == "openai_compatible" && "$configured" == "false" ]]; then
    echo "WARN: OPENAI_API_BASE not set — HTTP inference unset (use mistral.rs primary or set OPENAI_*)."
  fi
else
  if ! grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' "$STACK_JSON"; then
    echo "FAIL: stack-status JSON missing status ok (install jq for detailed errors)"
    exit 1
  fi
  if ! grep -q '"tool_policy"' "$STACK_JSON"; then
    echo "FAIL: stack-status missing tool_policy (install jq for detailed errors)"
    exit 1
  fi
  echo "OK: /api/stack-status (basic grep; install jq for full checks)"
fi

echo "PASS: chump-preflight"
exit 0
