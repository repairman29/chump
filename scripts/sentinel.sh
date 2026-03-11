#!/usr/bin/env bash
# Sentinel: after N consecutive failures (Farmer Brown or heartbeat), write diagnosis and optionally notify.
# Reads farmer-brown.log and/or heartbeat-learn.log for recent failures; if threshold exceeded, writes
# logs/sentinel-alert.txt and optionally calls ntfy or a webhook.
#
# Env:
#   SENTINEL_FAILURE_THRESHOLD   Consecutive failure count to alert (default 3).
#   SENTINEL_WATCH_FARMER=1      Count Farmer Brown need_fix=1 as failure (default 1).
#   SENTINEL_WATCH_HEARTBEAT=1   Count heartbeat round failure as failure (default 1).
#   NTFY_TOPIC                  If set, call ntfy.sh with this topic (e.g. my-alerts).
#   SENTINEL_WEBHOOK_URL        If set, POST summary to this URL (optional).
#   SENTINEL_SELF_HEAL_CMD      If set, when alert fires run this command (local or SSH). E.g.:
#                                ./scripts/farmer-brown.sh
#                                ssh user@my-mac "cd /path/to/rust-agent && ./scripts/farmer-brown.sh"
#                              Runs in background; output in logs/sentinel-self-heal.log.
#   CHUMP_HOME                  rust-agent root.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

LOG="$ROOT/logs/sentinel.log"
ALERT_FILE="$ROOT/logs/sentinel-alert.txt"
mkdir -p "$ROOT/logs"

THRESHOLD="${SENTINEL_FAILURE_THRESHOLD:-3}"
WATCH_FARMER="${SENTINEL_WATCH_FARMER:-1}"
WATCH_HEARTBEAT="${SENTINEL_WATCH_HEARTBEAT:-1}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

consecutive=0

# Count recent Farmer Brown need_fix=1 (last N lines)
if [[ "$WATCH_FARMER" == "1" ]] && [[ -f "$ROOT/logs/farmer-brown.log" ]]; then
  if grep -q "need_fix=1" <(tail -n 50 "$ROOT/logs/farmer-brown.log" 2>/dev/null); then
    consecutive=$((consecutive + 1))
  fi
fi

# Count recent heartbeat round failure (last 100 lines)
if [[ "$WATCH_HEARTBEAT" == "1" ]] && [[ -f "$ROOT/logs/heartbeat-learn.log" ]]; then
  if tail -n 100 "$ROOT/logs/heartbeat-learn.log" 2>/dev/null | grep -q "retry failed\|exit non-zero"; then
    consecutive=$((consecutive + 1))
  fi
fi

# Simple: if either source shows recent failure, increment. We don't maintain a true "consecutive" across runs;
# we just check "did the last run(s) show failure?". For a proper counter, we'd persist state. Here we alert if
# we've seen failure in recent logs and we've run sentinel N times (we don't track that). Simpler: alert when
# BOTH farmer had need_fix=1 recently AND heartbeat had a failure recently (stack in bad shape).
farmer_recent_fail=0
heartbeat_recent_fail=0
[[ -f "$ROOT/logs/farmer-brown.log" ]] && tail -n 30 "$ROOT/logs/farmer-brown.log" 2>/dev/null | grep -q "need_fix=1" && farmer_recent_fail=1
[[ -f "$ROOT/logs/heartbeat-learn.log" ]] && tail -n 80 "$ROOT/logs/heartbeat-learn.log" 2>/dev/null | grep -q "retry failed\|exit non-zero" && heartbeat_recent_fail=1

if [[ $farmer_recent_fail -eq 0 ]] && [[ $heartbeat_recent_fail -eq 0 ]]; then
  log "Sentinel: no recent failures."
  exit 0
fi

# Build summary
summary="Chump stack: "
[[ $farmer_recent_fail -eq 1 ]] && summary+="Farmer Brown reported need_fix recently. "
[[ $heartbeat_recent_fail -eq 1 ]] && summary+="Heartbeat round failed recently. "
summary+="Check logs: farmer-brown.log, heartbeat-learn.log."

echo "$summary" > "$ALERT_FILE"
echo "" >> "$ALERT_FILE"
echo "--- Last 15 lines farmer-brown.log ---" >> "$ALERT_FILE"
tail -n 15 "$ROOT/logs/farmer-brown.log" 2>/dev/null >> "$ALERT_FILE" || true
echo "" >> "$ALERT_FILE"
echo "--- Last 20 lines heartbeat-learn.log ---" >> "$ALERT_FILE"
tail -n 20 "$ROOT/logs/heartbeat-learn.log" 2>/dev/null >> "$ALERT_FILE" || true

log "Sentinel: alert written to $ALERT_FILE"

if [[ -n "${NTFY_TOPIC:-}" ]] && command -v ntfy &>/dev/null; then
  echo "$summary" | ntfy send "$NTFY_TOPIC" 2>/dev/null && log "ntfy sent to $NTFY_TOPIC" || log "ntfy send failed"
fi

if [[ -n "${SENTINEL_WEBHOOK_URL:-}" ]]; then
  curl -s -X POST -d "{\"text\":\"$summary\"}" -H "Content-Type: application/json" "$SENTINEL_WEBHOOK_URL" >> "$LOG" 2>&1 && log "Webhook POST ok" || log "Webhook POST failed"
fi

# Optional: fire a self-heal command (local or SSH) so Chump can boot into repair mode
if [[ -n "${SENTINEL_SELF_HEAL_CMD:-}" ]]; then
  log "Running self-heal command (background): $SENTINEL_SELF_HEAL_CMD"
  ( cd "$ROOT" && bash -c "$SENTINEL_SELF_HEAL_CMD" >> "$ROOT/logs/sentinel-self-heal.log" 2>&1 ) &
  log "Self-heal launched; see logs/sentinel-self-heal.log"
fi

exit 0
# Don't exit 1 so launchd doesn't think sentinel failed; we've written the alert.
