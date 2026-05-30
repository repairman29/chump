#!/usr/bin/env bash
# install-do-droplet-runner.sh — INFRA-2300 (CI-speed Tier 3)
#
# Creates a DigitalOcean droplet and registers it as a GitHub Actions self-hosted
# Linux runner for the chump/repairman29 repo. Adds a persistent +1 Linux runner
# slot at approximately $24/mo for the default s-4vcpu-8gb size.
#
# Architecture rationale: docs/process/SELF_HOSTED_RUNNER_DO.md
#
# Usage:
#   DO_API_TOKEN=<tok> GITHUB_PAT=<tok> bash scripts/setup/install-do-droplet-runner.sh
#
# Required env:
#   DO_API_TOKEN   — DigitalOcean API token with read+write scope
#   GITHUB_PAT     — GitHub PAT with repo or admin:org scope
#
# Optional env (all have sensible defaults):
#   DROPLET_NAME    (default: chump-runner-do-1)
#   DROPLET_REGION  (default: nyc3)
#   DROPLET_SIZE    (default: s-4vcpu-8gb, ~$24/mo)
#   DROPLET_IMAGE   (default: ubuntu-24-04-x64)
#   RUNNER_VERSION  (default: 2.319.1)
#   RUNNER_LABELS   (default: self-hosted,Linux,X64,chump-fleet,linux-burst)
#
# Rust-First-Bypass: install wrapper for GitHub actions-runner on a remote host;
#   pure shell glue around curl/doctl + ssh; no state mutation in state.db.
#   Per META-064 shell-OK criteria.

set -euo pipefail

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"

DROPLET_NAME="${DROPLET_NAME:-chump-runner-do-1}"
DROPLET_REGION="${DROPLET_REGION:-nyc3}"
DROPLET_SIZE="${DROPLET_SIZE:-s-4vcpu-8gb}"
DROPLET_IMAGE="${DROPLET_IMAGE:-ubuntu-24-04-x64}"
RUNNER_VERSION="${RUNNER_VERSION:-2.319.1}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64,chump-fleet,linux-burst}"

AMBIENT="${CHUMP_AMBIENT_LOG:-"$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null)/.chump-locks/ambient.jsonl"}"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf '[install-do-runner] %s\n' "$*"; }
warn() { printf '[install-do-runner] WARN: %s\n' "$*" >&2; }
die()  {
  local step="${1:-unknown}" reason="${2:-unspecified}"
  printf '[install-do-runner] ERROR step=%s: %s\n' "$step" "$reason" >&2
  emit_ambient "do_droplet_runner_install_failed" "{\"step\":\"$step\",\"reason\":\"$reason\",\"droplet\":\"$DROPLET_NAME\"}"
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
  die "validate_env" "DO_API_TOKEN is not set. Get one at https://cloud.digitalocean.com/account/api/tokens"
fi
if [ -z "${GITHUB_PAT:-}" ]; then
  die "validate_env" "GITHUB_PAT is not set. Get one at https://github.com/settings/tokens (needs repo or admin:org scope)"
fi

log "Starting DigitalOcean droplet runner install"
log "  Droplet name  : $DROPLET_NAME"
log "  Region        : $DROPLET_REGION"
log "  Size          : $DROPLET_SIZE"
log "  Image         : $DROPLET_IMAGE"
log "  Runner version: $RUNNER_VERSION"
log "  Runner labels : $RUNNER_LABELS"
log "  Repo          : https://github.com/$REPO_OWNER/$REPO_NAME"

# ── Step 1: Check doctl or fall back to raw curl ───────────────────────────────

USE_DOCTL=0
if command -v doctl >/dev/null 2>&1; then
  USE_DOCTL=1
  log "doctl found — using doctl for droplet management"
  # Authenticate doctl with the provided token
  doctl auth init --access-token "$DO_API_TOKEN" >/dev/null 2>&1 || true
else
  log "doctl not found — using raw DO REST API via curl"
fi

# ── Step 2: Create droplet ─────────────────────────────────────────────────────

log "Creating droplet '$DROPLET_NAME'..."

if [ "$USE_DOCTL" = "1" ]; then
  DROPLET_OUTPUT="$(doctl compute droplet create "$DROPLET_NAME" \
    --size "$DROPLET_SIZE" \
    --image "$DROPLET_IMAGE" \
    --region "$DROPLET_REGION" \
    --wait \
    --format ID,PublicIPv4 \
    --no-header 2>&1)" || die "create_droplet" "doctl create failed: $DROPLET_OUTPUT"

  DROPLET_ID="$(printf '%s' "$DROPLET_OUTPUT" | awk '{print $1}')"
  DROPLET_IP="$(printf '%s' "$DROPLET_OUTPUT" | awk '{print $2}')"
else
  # Raw curl path using DO v2 API
  CREATE_PAYLOAD="{\"name\":\"$DROPLET_NAME\",\"region\":\"$DROPLET_REGION\",\"size\":\"$DROPLET_SIZE\",\"image\":\"$DROPLET_IMAGE\",\"tags\":[\"chump-fleet\",\"self-hosted-runner\"]}"

  CREATE_RESPONSE="$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DO_API_TOKEN" \
    -d "$CREATE_PAYLOAD" \
    "https://api.digitalocean.com/v2/droplets")" || die "create_droplet" "DO API create call failed"

  DROPLET_ID="$(printf '%s' "$CREATE_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['droplet']['id'])" 2>/dev/null)" \
    || die "create_droplet" "Failed to parse droplet ID from API response"

  log "Droplet created (ID=$DROPLET_ID). Waiting for active status and IP..."

  # Poll for active status up to 120 s
  POLL_LIMIT=24
  POLL_COUNT=0
  DROPLET_IP=""
  while [ "$POLL_COUNT" -lt "$POLL_LIMIT" ]; do
    DROPLET_STATUS_RESP="$(curl -sf \
      -H "Authorization: Bearer $DO_API_TOKEN" \
      "https://api.digitalocean.com/v2/droplets/$DROPLET_ID")" || true

    STATUS="$(printf '%s' "$DROPLET_STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['droplet']['status'])" 2>/dev/null || echo "unknown")"

    if [ "$STATUS" = "active" ]; then
      DROPLET_IP="$(printf '%s' "$DROPLET_STATUS_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
networks = d['droplet']['networks'].get('v4', [])
for n in networks:
    if n.get('type') == 'public':
        print(n['ip_address'])
        break
" 2>/dev/null || echo "")"
      if [ -n "$DROPLET_IP" ]; then
        break
      fi
    fi

    POLL_COUNT=$((POLL_COUNT + 1))
    log "Waiting for droplet to come active (attempt $POLL_COUNT/$POLL_LIMIT, status=$STATUS)..."
    sleep 5
  done

  if [ -z "$DROPLET_IP" ]; then
    die "create_droplet" "Droplet $DROPLET_ID did not reach active+IP within 120s"
  fi
fi

if [ -z "$DROPLET_IP" ]; then
  die "create_droplet" "Could not determine public IP for droplet $DROPLET_NAME"
fi

log "Droplet ready: ID=$DROPLET_ID  IP=$DROPLET_IP"

# ── Step 3: Wait for SSH to become reachable ──────────────────────────────────

log "Waiting for SSH on $DROPLET_IP..."
SSH_READY=0
SSH_ATTEMPTS=0
SSH_LIMIT=12  # 12 * 5s = 60s
while [ "$SSH_ATTEMPTS" -lt "$SSH_LIMIT" ]; do
  if ssh -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=no \
         -o BatchMode=yes \
         "root@$DROPLET_IP" "true" 2>/dev/null; then
    SSH_READY=1
    break
  fi
  SSH_ATTEMPTS=$((SSH_ATTEMPTS + 1))
  log "SSH not yet ready (attempt $SSH_ATTEMPTS/$SSH_LIMIT)..."
  sleep 5
done

if [ "$SSH_READY" = "0" ]; then
  die "wait_ssh" "SSH not reachable on $DROPLET_IP after 60s"
fi

log "SSH reachable on $DROPLET_IP"

# ── Step 4: Install software + register runner via SSH ────────────────────────

log "Running remote install on $DROPLET_IP..."

ssh -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "root@$DROPLET_IP" \
    "GITHUB_PAT='$GITHUB_PAT' \
     RUNNER_VERSION='$RUNNER_VERSION' \
     RUNNER_LABELS='$RUNNER_LABELS' \
     DROPLET_NAME='$DROPLET_NAME' \
     REPO_OWNER='$REPO_OWNER' \
     REPO_NAME='$REPO_NAME' \
     bash -s" <<'REMOTE_EOF'
set -euo pipefail

echo "[remote] Updating package lists and installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl tar git build-essential libssl-dev pkg-config ca-certificates 2>&1 | tail -5

echo "[remote] Installing Rust toolchain via rustup..."
curl -fsSL https://sh.rustup.rs | sh -s -- --default-toolchain stable -y --no-modify-path 2>&1 | tail -10
export PATH="$HOME/.cargo/bin:$PATH"

echo "[remote] Installing sccache from Mozilla releases..."
SCCACHE_VERSION="v0.8.2"
SCCACHE_URL="https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz"
curl -fsSL "$SCCACHE_URL" | tar -xz --strip-components=1 -C /usr/local/bin "sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" 2>/dev/null \
  || {
    echo "[remote] WARN: sccache prebuilt download failed — proceeding without sccache"
  }

echo "[remote] Creating runner user..."
id runner 2>/dev/null || useradd -m -s /bin/bash runner

echo "[remote] Downloading GitHub Actions runner v${RUNNER_VERSION}..."
RUNNER_DIR="/home/runner/actions-runner"
mkdir -p "$RUNNER_DIR"
RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
curl -fsSL "$RUNNER_URL" -o "/tmp/$RUNNER_TARBALL" \
  || { echo "[remote] ERROR: failed to download runner tarball from $RUNNER_URL"; exit 1; }

tar -xz -C "$RUNNER_DIR" -f "/tmp/$RUNNER_TARBALL"
rm -f "/tmp/$RUNNER_TARBALL"
chown -R runner:runner "$RUNNER_DIR"

echo "[remote] Fetching GitHub runner registration token..."
REG_TOKEN_RESP="$(curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: Bearer ${GITHUB_PAT}" \
  "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token")"

REG_TOKEN="$(printf '%s' "$REG_TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")"
if [ -z "$REG_TOKEN" ]; then
  echo "[remote] ERROR: failed to extract registration token from GitHub API response"
  echo "[remote] API response: $REG_TOKEN_RESP"
  exit 1
fi

echo "[remote] Configuring runner as '${DROPLET_NAME}' with labels '${RUNNER_LABELS}'..."
cd "$RUNNER_DIR"
sudo -u runner ./config.sh \
  --url "https://github.com/${REPO_OWNER}/${REPO_NAME}" \
  --token "$REG_TOKEN" \
  --labels "$RUNNER_LABELS" \
  --name "$DROPLET_NAME" \
  --unattended \
  --replace 2>&1

echo "[remote] Installing runner as systemd service..."
./svc.sh install runner 2>&1
./svc.sh start 2>&1

echo "[remote] Verifying service status..."
sleep 3
systemctl is-active "$(./svc.sh status 2>/dev/null | grep 'service name:' | awk '{print $NF}' || echo actions.runner.${REPO_OWNER}-${REPO_NAME}.${DROPLET_NAME})" 2>/dev/null \
  && echo "[remote] Service is active." \
  || echo "[remote] WARN: could not verify systemd service status via is-active (may still be running)"

echo "[remote] Install complete."
REMOTE_EOF

SSH_STATUS=$?
if [ "$SSH_STATUS" != "0" ]; then
  die "remote_install" "SSH remote install exited with status $SSH_STATUS"
fi

log "Remote install finished."

# ── Step 5: Wait for runner to appear online in GitHub API ────────────────────

log "Polling GitHub API for runner '$DROPLET_NAME' with status=online (up to 120s)..."

POLL_LIMIT=24  # 24 * 5s = 120s
POLL_COUNT=0
RUNNER_ONLINE=0

while [ "$POLL_COUNT" -lt "$POLL_LIMIT" ]; do
  RUNNERS_JSON="$(curl -fsSL \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: Bearer $GITHUB_PAT" \
    "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners" 2>/dev/null)" || true

  ONLINE_STATUS="$(printf '%s' "$RUNNERS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if r.get('name') == '$DROPLET_NAME' and r.get('status') == 'online':
        print('online')
        break
" 2>/dev/null || echo "")"

  if [ "$ONLINE_STATUS" = "online" ]; then
    RUNNER_ONLINE=1
    break
  fi

  POLL_COUNT=$((POLL_COUNT + 1))
  log "Runner not yet online (attempt $POLL_COUNT/$POLL_LIMIT)..."
  sleep 5
done

if [ "$RUNNER_ONLINE" = "0" ]; then
  warn "Runner '$DROPLET_NAME' not seen online in GitHub API within 120s."
  warn "It may still be starting up. Check: gh api /repos/$REPO_OWNER/$REPO_NAME/actions/runners"
  # Emit failure for the wait step but don't die — droplet + runner are installed
  emit_ambient "do_droplet_runner_install_failed" \
    "{\"step\":\"wait_runner_online\",\"reason\":\"not_seen_online_after_120s\",\"droplet\":\"$DROPLET_NAME\",\"ip\":\"$DROPLET_IP\"}"
else
  log "Runner '$DROPLET_NAME' is ONLINE."
fi

# ── Step 6: Success summary ───────────────────────────────────────────────────

printf '\n'
printf '╔══════════════════════════════════════════════════════════════╗\n'
printf '║          DO Droplet Runner — Install Complete                ║\n'
printf '╠══════════════════════════════════════════════════════════════╣\n'
printf '║  Droplet IP   : %-44s║\n' "$DROPLET_IP"
printf '║  Droplet ID   : %-44s║\n' "${DROPLET_ID:-unknown}"
printf '║  Runner name  : %-44s║\n' "$DROPLET_NAME"
printf '║  Labels       : %-44s║\n' "${RUNNER_LABELS:0:44}"
printf '║  Est. cost    : ~$24/mo (s-4vcpu-8gb)                        ║\n'
printf '╠══════════════════════════════════════════════════════════════╣\n'
if [ "$RUNNER_ONLINE" = "1" ]; then
printf '║  Status       : ONLINE (confirmed via GitHub API)            ║\n'
else
printf '║  Status       : install done; may need 1-2 min to appear     ║\n'
fi
printf '╠══════════════════════════════════════════════════════════════╣\n'
printf '║  Verify:                                                     ║\n'
printf '║  gh api /repos/%s/%s/actions/runners\n' "$REPO_OWNER" "$REPO_NAME"
printf '║    | jq '"'"'.runners[] | select(.name=="%s")'"'"'\n' "$DROPLET_NAME"
printf '╠══════════════════════════════════════════════════════════════╣\n'
printf '║  To uninstall:                                               ║\n'
printf '║  DO_API_TOKEN=... GITHUB_PAT=...                             ║\n'
printf '║  DROPLET_NAME=%s bash \\\n' "$DROPLET_NAME"
printf '║    scripts/setup/uninstall-do-droplet-runner.sh              ║\n'
printf '╚══════════════════════════════════════════════════════════════╝\n'
printf '\n'

emit_ambient "do_droplet_runner_installed" \
  "{\"droplet\":\"$DROPLET_NAME\",\"ip\":\"$DROPLET_IP\",\"id\":\"${DROPLET_ID:-unknown}\",\"labels\":\"$RUNNER_LABELS\",\"runner_version\":\"$RUNNER_VERSION\"}"
