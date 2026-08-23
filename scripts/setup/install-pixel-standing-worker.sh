#!/data/data/com.termux/files/usr/bin/env bash
# install-pixel-standing-worker.sh — RESILIENT-376: promote the Pixel from a
# proven one-shot into a DURABLE standing fleet worker.
#
# Installs TWO runit-supervised organs (the Termux-proof supervisor primitive
# already used by node-heartbeat / postgres), matching the exact service shape
# emitted by chump-node-install.sh:
#
#   nats-bridge   — durable ssh port-forward to CJ's localhost-only nats-server
#                   (Pixel :4222 -> CJ 127.0.0.1:4222) so `chump gap claim`
#                   reaches the shared NATS-KV coordinator. Auto-restarts on
#                   drop; survives reboot (runsvdir starts under Termux:Boot).
#   pixel-worker  — the pull->claim->build->ship loop, farmer-gated (idles
#                   until oauth is fresh), capability-tagged (arm64, xs/s,
#                   non-rust, docs/shell/scripts).
#
# Idempotent. Does NOT touch node-heartbeat, postgres, discord-gateway, sshd,
# or ssh-agent. Run ON the Pixel (Termux):
#   bash ~/.chumpnode/repo/scripts/setup/install-pixel-standing-worker.sh
set -uo pipefail

: "${PREFIX:?must run inside Termux (PREFIX unset)}"
SVC_DIR="$PREFIX/var/service"
NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
REPO_DIR="${CHUMP_REPO:-$HOME/chump-repo}"
ORGAN_DIR="$NODE_DIR/organs"
LOG_DIR="$NODE_DIR/logs"
# Where the running binary lives (the deploy target of build-android.sh).
CHUMP_HOME="${CHUMP_HOME:-$HOME/chump}"

ok(){   printf '\033[32m[ok]\033[0m %s\n' "$1"; }
info(){ printf '\033[36m[..]\033[0m %s\n' "$1"; }

mkdir -p "$ORGAN_DIR" "$LOG_DIR"

# --- point the organ scripts at the repo copies (single source of truth) ---
for organ in nats-bridge pixel-worker; do
  src="$REPO_DIR/scripts/setup/${organ}.sh"
  [ -f "$src" ] || { echo "missing $src — is CHUMP_REPO up to date?" >&2; exit 1; }
  ln -sfn "$src" "$ORGAN_DIR/${organ}.sh"
  chmod +x "$src" 2>/dev/null || true
done
ok "organs linked into $ORGAN_DIR"

# --- svc_install: mirror chump-node-install.sh's runit run/log shape ---
svc_install() {
  local name="$1" cmd="$2" extra_env="${3:-}"
  mkdir -p "$SVC_DIR/$name/log" "$LOG_DIR/$name"
  # exec via explicit bash: repo scripts use `#!/usr/bin/env bash` and Termux
  # runit has no /usr/bin/env (no termux-exec LD_PRELOAD) so the shebang fails.
  {
    printf '#!/data/data/com.termux/files/usr/bin/sh\n'
    printf 'exec 2>&1\n'
    printf 'export CHUMP_NODE_DIR=%s CHUMP_STATE_DIR=%s CHUMP_REPO=%s CHUMP_HOME=%s CHUMP_BIN=%s PYTHONUNBUFFERED=1\n' \
      "$NODE_DIR" "$STATE_DIR" "$REPO_DIR" "$CHUMP_HOME" "$CHUMP_HOME/chump"
    [ -n "$extra_env" ] && printf 'export %s\n' "$extra_env"
    printf 'termux-wake-lock 2>/dev/null || true\n'
    printf 'exec bash %s\n' "$cmd"
  } > "$SVC_DIR/$name/run"
  chmod +x "$SVC_DIR/$name/run"
  printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s\n' "$LOG_DIR/$name" > "$SVC_DIR/$name/log/run"
  chmod +x "$SVC_DIR/$name/log/run"
  ok "service installed: $name"
}

svc_install nats-bridge  "$ORGAN_DIR/nats-bridge.sh"
svc_install pixel-worker "$ORGAN_DIR/pixel-worker.sh"

# --- bring them up (runsvdir auto-detects the new dirs within ~5s) ---
info "waiting for runsvdir to notice new services..."
sleep 7
for name in nats-bridge pixel-worker; do
  sv up "$SVC_DIR/$name" 2>/dev/null || true
done

echo
info "status:"
for name in nats-bridge pixel-worker node-heartbeat postgres; do
  printf '  %-16s ' "$name"; sv status "$SVC_DIR/$name" 2>&1
done

cat <<'EOF'

Standing worker installed. The ONE remaining manual step (operator only):

    claude setup-token        # run ON the Pixel, writes ~/.chump/oauth-token.json

Until then the worker idles at the farmer gate (it will NOT claim gaps it can't
finish). The moment the token is fresh, it begins pulling+shipping automatically.
EOF
