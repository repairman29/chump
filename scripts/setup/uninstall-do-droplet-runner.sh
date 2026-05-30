#!/usr/bin/env bash
# uninstall-do-droplet-runner.sh — INFRA-2300 (CI-speed Tier 3)
#
# Cleanly removes the GitHub Actions self-hosted runner from the droplet,
# unregisters it from the repo, and destroys the DigitalOcean droplet.
#
# Usage:
#   DO_API_TOKEN=<tok> GITHUB_PAT=<tok> bash scripts/setup/uninstall-do-droplet-runner.sh
#   DO_API_TOKEN=<tok> GITHUB_PAT=<tok> DROPLET_NAME=my-runner \
#     bash scripts/setup/uninstall-do-droplet-runner.sh
#
# Required env:
#   DO_API_TOKEN   — DigitalOcean API token with read+write scope
#   GITHUB_PAT     — GitHub PAT with repo or admin:org scope
#
# Optional env:
#   DROPLET_NAME   (default: chump-runner-do-1)
#
# Rust-First-Bypass: teardown wrapper for GitHub runner on a remote host;
#   pure shell glue around curl/doctl + ssh; no state mutation in state.db.
#   Per META-064 shell-OK criteria.

set -euo pipefail

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"

DROPLET_NAME="${DROPLET_NAME:-chump-runner-do-1}"

AMBIENT="${CHUMP_AMBIENT_LOG:-"$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null)/.chump-locks/ambient.jsonl"}"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf '[uninstall-do-runner] %s\n' "$*"; }
warn() { printf '[uninstall-do-runner] WARN: %s\n' "$*" >&2; }
die()  {
  local msg="${1:-unspecified error}"
  printf '[uninstall-do-runner] ERROR: %s\n' "$msg" >&2
  exit 1
}

emit_ambient() {
  local kind="$1" extra="${2:-{}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -f "$AMBIENT" ] || [ -d "$(dirname "$AMBIENT")" ]; then
    printf '{"ts":"%s","kind":"%s",%s}\n' \
      "$ts" "$kind" "${extra#\{}" >> "$AMBIENT" 2>/dev/null || true
  fi
}

# ── Step 0: Validate required env ─────────────────────────────────────────────

if [ -z "${DO_API_TOKEN:-}" ]; then
  die "DO_API_TOKEN is not set."
fi
if [ -z "${GITHUB_PAT:-}" ]; then
  die "GITHUB_PAT is not set."
fi

log "Uninstalling DigitalOcean droplet runner"
log "  Droplet name : $DROPLET_NAME"
log "  Repo         : https://github.com/$REPO_OWNER/$REPO_NAME"

# ── Step 1: Look up the droplet to get its IP ─────────────────────────────────

USE_DOCTL=0
if command -v doctl >/dev/null 2>&1; then
  USE_DOCTL=1
  doctl auth init --access-token "$DO_API_TOKEN" >/dev/null 2>&1 || true
fi

DROPLET_ID=""
DROPLET_IP=""

if [ "$USE_DOCTL" = "1" ]; then
  LOOKUP="$(doctl compute droplet list --format ID,Name,PublicIPv4 --no-header 2>/dev/null | grep "$DROPLET_NAME" || true)"
  if [ -n "$LOOKUP" ]; then
    DROPLET_ID="$(printf '%s' "$LOOKUP" | awk '{print $1}')"
    DROPLET_IP="$(printf '%s' "$LOOKUP" | awk '{print $3}')"
  fi
else
  LIST_RESP="$(curl -sf \
    -H "Authorization: Bearer $DO_API_TOKEN" \
    "https://api.digitalocean.com/v2/droplets?per_page=100" 2>/dev/null)" || LIST_RESP="{}"

  DROPLET_INFO="$(printf '%s' "$LIST_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for d in data.get('droplets', []):
    if d.get('name') == '$DROPLET_NAME':
        ip = ''
        for n in d.get('networks', {}).get('v4', []):
            if n.get('type') == 'public':
                ip = n['ip_address']
                break
        print(str(d['id']) + ' ' + ip)
        break
" 2>/dev/null || echo "")"

  if [ -n "$DROPLET_INFO" ]; then
    DROPLET_ID="$(printf '%s' "$DROPLET_INFO" | awk '{print $1}')"
    DROPLET_IP="$(printf '%s' "$DROPLET_INFO" | awk '{print $2}')"
  fi
fi

if [ -z "$DROPLET_ID" ]; then
  warn "Droplet '$DROPLET_NAME' not found in DO account. It may have already been destroyed."
  warn "Attempting GitHub runner de-registration only (if PAT is valid)."
fi

# ── Step 2: De-register runner via SSH (if droplet is reachable) ──────────────

if [ -n "$DROPLET_IP" ]; then
  log "Attempting SSH to $DROPLET_IP to stop and remove runner service..."
  SSH_OK=0
  if ssh -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=no \
         -o BatchMode=yes \
         "root@$DROPLET_IP" "true" 2>/dev/null; then
    SSH_OK=1
  fi

  if [ "$SSH_OK" = "1" ]; then
    REMOVAL_TOKEN_RESP="$(curl -fsSL \
      -X POST \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Authorization: Bearer $GITHUB_PAT" \
      "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners/remove-token" 2>/dev/null)" || REMOVAL_TOKEN_RESP="{}"

    REMOVAL_TOKEN="$(printf '%s' "$REMOVAL_TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")"

    if [ -n "$REMOVAL_TOKEN" ]; then
      ssh -o StrictHostKeyChecking=no \
          -o BatchMode=yes \
          "root@$DROPLET_IP" \
          "REMOVAL_TOKEN='$REMOVAL_TOKEN' \
           REPO_OWNER='$REPO_OWNER' \
           REPO_NAME='$REPO_NAME' \
           DROPLET_NAME='$DROPLET_NAME' \
           bash -s" <<'REMOTE_EOF' || warn "Remote runner removal script exited non-zero (proceeding with droplet destroy)"
set -euo pipefail
RUNNER_DIR="/home/runner/actions-runner"

if [ ! -d "$RUNNER_DIR" ]; then
  echo "[remote] Runner directory $RUNNER_DIR not found — skipping service removal"
  exit 0
fi

cd "$RUNNER_DIR"

# Stop and uninstall systemd service
if [ -f "./svc.sh" ]; then
  echo "[remote] Stopping runner service..."
  ./svc.sh stop 2>/dev/null || true
  echo "[remote] Uninstalling runner service..."
  ./svc.sh uninstall 2>/dev/null || true
fi

# Unregister from GitHub
if [ -f "./config.sh" ]; then
  echo "[remote] Removing runner registration..."
  sudo -u runner ./config.sh remove --token "$REMOVAL_TOKEN" 2>/dev/null || true
fi

echo "[remote] Runner service and registration removed."
REMOTE_EOF
    else
      warn "Could not obtain removal token from GitHub API — attempting service stop only"
      ssh -o StrictHostKeyChecking=no \
          -o BatchMode=yes \
          "root@$DROPLET_IP" \
          'RUNNER_DIR="/home/runner/actions-runner"; \
           [ -d "$RUNNER_DIR" ] && cd "$RUNNER_DIR" && ./svc.sh stop 2>/dev/null || true; \
           [ -d "$RUNNER_DIR" ] && cd "$RUNNER_DIR" && ./svc.sh uninstall 2>/dev/null || true; \
           echo "[remote] Service stop attempted."' || warn "Service stop failed — proceeding with droplet destroy anyway"
    fi

    log "Remote runner removal complete."
  else
    warn "SSH to $DROPLET_IP not reachable (timeout). Proceeding to destroy droplet without graceful shutdown."
  fi
fi

# ── Step 3: De-register runner via GitHub API (belt-and-suspenders) ──────────

log "Checking GitHub API for remaining runner registration '$DROPLET_NAME'..."

RUNNERS_JSON="$(curl -fsSL \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: Bearer $GITHUB_PAT" \
  "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners" 2>/dev/null)" || RUNNERS_JSON="{}"

RUNNER_API_ID="$(printf '%s' "$RUNNERS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if r.get('name') == '$DROPLET_NAME':
        print(r['id'])
        break
" 2>/dev/null || echo "")"

if [ -n "$RUNNER_API_ID" ]; then
  log "Removing runner ID=$RUNNER_API_ID via GitHub API..."
  curl -fsSL \
    -X DELETE \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: Bearer $GITHUB_PAT" \
    "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners/$RUNNER_API_ID" >/dev/null 2>&1 \
    && log "Runner de-registered via GitHub API." \
    || warn "GitHub API delete returned non-2xx — runner may already be gone."
else
  log "Runner '$DROPLET_NAME' not found in GitHub API (already removed or never registered)."
fi

# ── Step 4: Destroy the droplet ───────────────────────────────────────────────

if [ -n "$DROPLET_ID" ]; then
  log "Destroying droplet ID=$DROPLET_ID ($DROPLET_NAME)..."

  if [ "$USE_DOCTL" = "1" ]; then
    doctl compute droplet delete "$DROPLET_ID" --force 2>&1 \
      && log "Droplet $DROPLET_ID destroyed via doctl." \
      || warn "doctl delete returned non-zero — droplet may already be gone."
  else
    HTTP_STATUS="$(curl -sf -o /dev/null -w '%{http_code}' \
      -X DELETE \
      -H "Authorization: Bearer $DO_API_TOKEN" \
      "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" 2>/dev/null || echo "000")"

    if [ "$HTTP_STATUS" = "204" ] || [ "$HTTP_STATUS" = "200" ]; then
      log "Droplet $DROPLET_ID destroyed via DO API (HTTP $HTTP_STATUS)."
    else
      warn "DO API delete returned HTTP $HTTP_STATUS — droplet may already be gone or delete initiated async."
    fi
  fi
else
  warn "No droplet ID found — skipping destroy step."
fi

# ── Done ──────────────────────────────────────────────────────────────────────

printf '\n'
printf '╔══════════════════════════════════════════════════════════════╗\n'
printf '║       DO Droplet Runner — Uninstall Complete                 ║\n'
printf '╠══════════════════════════════════════════════════════════════╣\n'
printf '║  Droplet name : %-44s║\n' "$DROPLET_NAME"
if [ -n "$DROPLET_ID" ]; then
printf '║  Droplet ID   : %-44s║\n' "$DROPLET_ID"
fi
printf '║  Runner       : removed from %s/%s\n' "$REPO_OWNER" "$REPO_NAME"
printf '╠══════════════════════════════════════════════════════════════╣\n'
printf '║  Verify runner gone:                                         ║\n'
printf '║  gh api /repos/%s/%s/actions/runners\n' "$REPO_OWNER" "$REPO_NAME"
printf '╚══════════════════════════════════════════════════════════════╝\n'
printf '\n'

emit_ambient "do_droplet_runner_install_failed" \
  "{\"step\":\"uninstall_complete\",\"reason\":\"operator_requested_teardown\",\"droplet\":\"$DROPLET_NAME\",\"droplet_id\":\"${DROPLET_ID:-unknown}\"}" 2>/dev/null || true
# Note: reusing do_droplet_runner_install_failed kind for teardown telemetry
# to avoid introducing a new kind for an infrequent operator action.
# A dedicated kind can be added via a follow-up gap if needed.

log "Uninstall complete."
