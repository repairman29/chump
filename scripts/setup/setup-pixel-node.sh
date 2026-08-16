#!/data/data/com.termux/files/usr/bin/bash
# setup-pixel-node.sh — RESILIENT-336: one-command Pixel 8 Pro node install.
# Runs IN Termux on the phone. Idempotent — safe to re-run.
#
# What it does:
#   1. installs the node scripts (worker + supervisor) into ~/
#   2. stages the Termux:Boot hook (sshd + supervisor) so the node self-restores
#      on reboot (needs the Termux:Boot app installed separately — F-Droid)
#   3. sets express-lane worker env defaults in ~/chump/.env (skills, machine,
#      NATS URL) — provider/LLM keys are synced from the Mac separately
#      (they are secrets and must not be committed)
#   4. starts the supervisor (which starts the worker + witness)
#
# Usage (in Termux):
#   bash ~/chump-repo/scripts/setup/setup-pixel-node.sh
#
# Prereqs (done before this runs, or done once):
#   - chump aarch64 binary at ~/chump/chump (cross-compiled on the Mac:
#     scripts/setup/build-android.sh)
#   - provider keys in ~/chump/.env (synced from the Mac)

set -uo pipefail

PREFIX=/data/data/com.termux/files/usr
HOME_DIR="$HOME"
REPO="${CHUMP_REPO:-$HOME_DIR/chump-repo}"
DEPLOY="${CHUMP_HOME:-$HOME_DIR/chump}"
BOOT_DIR="$HOME_DIR/.termux/boot"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[setup-pixel] $*"; }

# ── 1. install node scripts into ~/ ────────────────────────────────────────
log "installing node scripts from $HERE"
cp -f "$HERE/pixel-worker.sh" "$HOME_DIR/pixel-worker.sh"
cp -f "$HERE/pixel-node-supervisor.sh" "$HOME_DIR/pixel-node-supervisor.sh"
chmod +x "$HOME_DIR/pixel-worker.sh" "$HOME_DIR/pixel-node-supervisor.sh"

# witness probe (creds live in ~/.witness-env — never committed; the probe
# reads DISCORD_TOKEN + CHUMP_READY_DM_USER_ID from there at runtime)
mkdir -p "$HOME_DIR/witness"
cp -f "$HERE/witness/probe.py" "$HOME_DIR/witness/probe.py"
cp -f "$HERE/witness/run.sh" "$HOME_DIR/witness/run.sh"
chmod +x "$HOME_DIR/witness/run.sh"

# ── 2. stage the boot hook (fires once Termux:Boot is installed) ───────────
log "staging boot hook at $BOOT_DIR"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/00-node.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Pixel node boot hook — RESILIENT-336. Starts sshd + the node supervisor so
# the worker + witness self-restore after a reboot.
sshd
termux-wake-lock 2>/dev/null
nohup ~/pixel-node-supervisor.sh >> ~/pixel-supervisor.log 2>&1 &
EOF
chmod +x "$BOOT_DIR/00-node.sh"

# ── 3. env defaults (express-lane; secrets synced separately) ─────────────
log "setting env defaults in $DEPLOY/.env"
mkdir -p "$DEPLOY"
touch "$DEPLOY/.env"
set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$DEPLOY/.env" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$DEPLOY/.env"
    else
        echo "${key}=${val}" >> "$DEPLOY/.env"
    fi
}
set_env WORKER_SKILLS "docs,shell,scripts,md"
set_env WORKER_MACHINE "pixel-8-pro"
set_env CHUMP_WORK_BACKEND "chump-local"
set_env CHUMP_NATS_URL "nats://100.101.188.30:4222"

# ── 4. start the supervisor (idempotent) ───────────────────────────────────
if kill -0 "$(cat "$HOME_DIR/.pixel-supervisor.pid" 2>/dev/null)" 2>/dev/null; then
    log "supervisor already running (pid $(cat "$HOME_DIR/.pixel-supervisor.pid"))"
else
    log "starting supervisor"
    nohup "$HOME_DIR/pixel-node-supervisor.sh" >> "$HOME_DIR/pixel-supervisor.log" 2>&1 &
    echo $! > "$HOME_DIR/.pixel-supervisor.pid"
fi

log "done. worker + witness supervised; boot hook staged (install Termux:Boot from F-Droid to activate it)."
