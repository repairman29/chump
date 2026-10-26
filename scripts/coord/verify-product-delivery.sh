#!/usr/bin/env bash
# scripts/coord/verify-product-delivery.sh — CREDIBLE-1647
#
# Live-delivery probe for PRODUCT-* gaps. Verifies that a merged product change
# is actually live (HTTP endpoint 200, systemd unit active, or custom probe command)
# and emits a machine-readable delivery receipt + kind=product_delivery_verified.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

GAP_ID=""
URL=""
UNIT=""
PROBE_CMD=""
DEPLOY_ID="${CHUMP_DEPLOY_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gap-id)    GAP_ID="${2:-}"; shift 2 ;;
    --url)       URL="${2:-}"; shift 2 ;;
    --unit)      UNIT="${2:-}"; shift 2 ;;
    --cmd)       PROBE_CMD="${2:-}"; shift 2 ;;
    --deploy-id) DEPLOY_ID="${2:-}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -z "$DEPLOY_ID" ]]; then
  DEPLOY_ID="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
fi

probe_status="failed"
unit_state="unknown"

if [[ -n "$URL" ]]; then
  http_code="$(curl -fsSL -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null || echo 000)"
  if [[ "$http_code" == "200" ]]; then
    probe_status="ok"
    unit_state="http_200"
  else
    unit_state="http_${http_code}"
  fi
elif [[ -n "$UNIT" ]]; then
  systemctl_bin="${CHUMP_SYSTEMCTL_BIN:-systemctl}"
  if "$systemctl_bin" is-active --quiet "$UNIT" 2>/dev/null; then
    probe_status="ok"
    unit_state="active"
  else
    unit_state="inactive"
  fi
elif [[ -n "$PROBE_CMD" ]]; then
  if bash -c "$PROBE_CMD" >/dev/null 2>&1; then
    probe_status="ok"
    unit_state="cmd_ok"
  else
    unit_state="cmd_failed"
  fi
else
  echo "ERROR: specify at least one of --url, --unit, or --cmd" >&2
  exit 2
fi

receipt="$(python3 - "$GAP_ID" "$probe_status" "$ts" "$DEPLOY_ID" "$unit_state" <<'PY'
import json, sys
gap_id, probe_status, verified_at, deploy_id, unit_state = sys.argv[1:6]
obj = {
    "gap_id": gap_id,
    "probe_status": probe_status,
    "verified_at": verified_at,
    "deploy_id": deploy_id,
    "unit_state": unit_state,
}
print(json.dumps(obj, separators=(",", ":")))
PY
)"

if [[ "$probe_status" == "ok" ]]; then
  mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"product_delivery_verified","gap_id":"%s","probe_status":"ok","verified_at":"%s","deploy_id":"%s","unit_state":"%s"}\n' \
    "$ts" "$GAP_ID" "$ts" "$DEPLOY_ID" "$unit_state" >> "$AMBIENT_LOG" 2>/dev/null || true
  printf '%s\n' "$receipt"
  exit 0
fi

printf '%s\n' "$receipt" >&2
exit 1
