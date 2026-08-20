#!/usr/bin/env bash
# install-node-housekeeping.sh — ONE COMMAND: install ChumpOS's self-management suite on ANY
# owned node so it keeps itself managed/clean/operable/hardware-aware. Idempotent + host-agnostic.
# Called by chump-node-install.sh (COTG). RESILIENT-318 / DISK_AWARE_FLEET.
#
# Installs, as supervised loop-services wrapping the TRACKED repo scripts (never reinvented):
#   node-orchestrator  — the resource-aware brain (sense cores/RAM/disk → heal/scale/place)
#   rot-reaper         — drain CONFLICTING PRs (RESILIENT-324)
#   armed-pr-rebaser   — SALVAGE organ: rebases armed BEHIND/DIRTY PRs onto main so
#                        the reaper never has to close them (RESILIENT-346)
#   worktree-reaper    — reclaim disk from merged/dead worktrees
#   disk-monitor       — disk headroom alarm + auto-remediate
#   reviver            — reopen closed-but-gap-open fleet PRs = work wrongly trashed by a
#                        stale-base auto-close (INFRA-2026 post-push-integrity-watch, RESILIENT-341)
# The orchestrator then keeps the others alive (heal loop). One install, self-managing node.
set -uo pipefail
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
STATE="${CHUMP_STATE_DIR:-$HOME/.chump}"
USER_N="$(id -un)"
log(){ printf '  \033[36m[housekeeping]\033[0m %s\n' "$*"; }

[ -d "$REPO/.git" ] || { echo "no repo at $REPO (set CHUMP_REPO_ROOT)"; exit 1; }
mkdir -p "$STATE/organs"

# supervisor detect
if [ -n "${PREFIX:-}" ] && printf '%s' "${PREFIX:-}" | grep -q com.termux; then SUP=runit; SVDIR="$PREFIX/var/service"
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then SUP=systemd
else SUP=nohup; fi
log "supervisor=$SUP repo=$REPO user=$USER_N"

# organ table: name|repo-relative-script[ args]|cadence-seconds (0 = script self-loops, e.g. orchestrator)
ORGANS="node-orchestrator|scripts/ops/node-orchestrator.sh|0
rot-reaper|scripts/ops/rot-reaper.sh|1800
armed-pr-rebaser|scripts/coord/armed-pr-rebaser.sh|600
worktree-reaper|scripts/ops/stale-worktree-reaper.sh --execute|900
disk-monitor|scripts/ops/disk-health-monitor.sh|300
main-health-watchdog|scripts/ops/main-health-watchdog.sh|600
pr-lander|scripts/dispatch/pr-lander-beat.sh|600
cargo-sweep-gc|scripts/ops/cargo-sweep-gc.sh|3600
reviver|scripts/coord/post-push-integrity-watch.sh|60"

# write the self-contained loop-runner for an organ (sources creds, sets PATH, loops at cadence)
write_runner() {
  local name="$1" script="$2" cadence="$3"
  cat > "$STATE/organs/$name.sh" <<RUN
#!/usr/bin/env bash
# NB: NO 'set -u' — providers.env references unbound vars; sourcing it under set -u
# terminates the shell (|| true cannot catch a set-u exit). Documented fleet gotcha.
set -o pipefail
cd "$REPO" 2>/dev/null || exit 1
set -a; . "$STATE/providers.env" 2>/dev/null || true; . "$STATE/cj.env" 2>/dev/null || true; set +a
export PATH="$REPO/target/release:\$PATH" CHUMP_REPO_ROOT="$REPO" CHUMP_STATE_DIR="$STATE" CHUMP_BINARY_STALENESS_CHECK=0
if [ "$cadence" -eq 0 ]; then exec bash "$REPO"/$script
else while true; do bash "$REPO"/$script >/dev/null 2>&1 || true; sleep $cadence; done; fi
RUN
  chmod +x "$STATE/organs/$name.sh"
}

install_systemd() {
  local name="$1"
  sudo tee /etc/systemd/system/chump-$name.service >/dev/null <<UNIT
[Unit]
Description=ChumpOS housekeeping organ: $name (RESILIENT-318)
After=network-online.target
[Service]
Type=simple
User=$USER_N
ExecStart=/bin/bash $STATE/organs/$name.sh
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl enable --now "chump-$name.service" >/dev/null 2>&1
}
install_runit() {
  local name="$1"
  mkdir -p "$SVDIR/chump-$name/log"
  printf '#!/data/data/com.termux/files/usr/bin/sh\nexec 2>&1\nexec bash %s\n' "$STATE/organs/$name.sh" > "$SVDIR/chump-$name/run"
  chmod +x "$SVDIR/chump-$name/run"
  printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s\n' "$STATE/organs/logs/$name" > "$SVDIR/chump-$name/log/run"
  chmod +x "$SVDIR/chump-$name/log/run"; mkdir -p "$STATE/organs/logs/$name"
}

# reconcile: retire any older hand-installed timer/service variants so we don't double-run
if [ "$SUP" = systemd ]; then
  for old in chump-rot-reaper.timer chump-worktree-reaper.timer chump-cj-disk-monitor.service; do
    sudo systemctl disable --now "$old" >/dev/null 2>&1 || true
  done
fi

while IFS='|' read -r name script cadence; do
  [ -z "$name" ] && continue
  write_runner "$name" "$script" "$cadence"
  case "$SUP" in
    systemd) install_systemd "$name" ;;
    runit)   install_runit "$name"; sv up "$SVDIR/chump-$name" 2>/dev/null || true ;;
    *)       nohup bash "$STATE/organs/$name.sh" >/dev/null 2>&1 & ;;
  esac
  log "installed + up: chump-$name"
done <<EOF
$ORGANS
EOF
[ "$SUP" = systemd ] && sudo systemctl daemon-reload

# self-test
log "self-test:"
fail=0
for name in node-orchestrator rot-reaper armed-pr-rebaser worktree-reaper disk-monitor main-health-watchdog pr-lander cargo-sweep-gc reviver; do
  case "$SUP" in
    systemd) systemctl is-active "chump-$name.service" >/dev/null 2>&1 && log "  ✓ $name up" || { log "  ✗ $name DOWN"; fail=1; } ;;
    runit)   sv status "$SVDIR/chump-$name" 2>/dev/null | grep -q '^run' && log "  ✓ $name up" || { log "  ✗ $name DOWN"; fail=1; } ;;
  esac
done
[ -f "$STATE/resource-inventory.json" ] && log "  ✓ orchestrator sensing (resource-inventory.json present)" || log "  … inventory not written yet (orchestrator warming up)"
[ "$fail" = 0 ] && log "HOUSEKEEPING INSTALLED ✓ — node self-manages" || { log "some organs down — check logs"; exit 1; }
