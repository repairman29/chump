#!/usr/bin/env bash
# install-node-housekeeping.sh — ONE COMMAND: install ChumpOS's self-management suite on ANY
# owned node so it keeps itself managed/clean/operable/hardware-aware. Idempotent + host-agnostic.
# Called by chump-node-install.sh (COTG). RESILIENT-318 / DISK_AWARE_FLEET / RESILIENT-320.
#
# ROLE-AWARE (RESILIENT-320): before this gap, every node got the FULL organ set
# regardless of role — a data node (Pixel) would get pr-lander + PR-reapers, which
# a data node must never run. Usage:
#   install-node-housekeeping.sh [--role factory|data|embed] [--worker-max N] [--dry-run]
#
# NB: $STATE/cj.env may already hold live credentials on a real node (it is
# sourced alongside providers.env by every organ runner) — CHUMP_ORCH_WORKER_MAX
# is UPSERTED into it (existing lines preserved), never overwritten wholesale.
#
# Installs, as supervised loop-services wrapping the TRACKED repo scripts (never reinvented):
#   node-orchestrator  — the resource-aware brain (sense cores/RAM/disk → heal/scale/place). ALL roles.
#   disk-monitor       — disk headroom alarm + auto-remediate. ALL roles.
#   main-health-watchdog — trunk-health watchdog. factory + data.
#   rot-reaper         — drain CONFLICTING PRs (RESILIENT-324). factory only.
#   worktree-reaper    — reclaim disk from merged/dead worktrees. factory only.
#   pr-lander          — arms green PRs so they merge. factory only — a data/embed node
#                         never lands PRs (AC1).
#   cargo-sweep-gc     — cap the cargo target dir. factory only.
#   integrator         — batched-merge-train daemon (best-effort, systemd+root). factory only.
# The orchestrator then keeps the role's organs alive (heal loop). One install, self-managing node.
set -uo pipefail
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
STATE="${CHUMP_STATE_DIR:-$HOME/.chump}"
USER_N="$(id -un)"
log(){ printf '  \033[36m[housekeeping]\033[0m %s\n' "$*"; }

ROLE="factory"; WORKER_MAX=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --worker-max) WORKER_MAX="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$ROLE" in factory|data|embed) ;; *) echo "role must be factory|data|embed" >&2; exit 2;; esac
run(){ [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

[ -d "$REPO/.git" ] || { echo "no repo at $REPO (set CHUMP_REPO_ROOT)"; exit 1; }
[ "$DRY" = 1 ] || mkdir -p "$STATE/organs"

# supervisor detect
if [ -n "${PREFIX:-}" ] && printf '%s' "${PREFIX:-}" | grep -q com.termux; then SUP=runit; SVDIR="$PREFIX/var/service"
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then SUP=systemd
else SUP=nohup; fi
log "supervisor=$SUP repo=$REPO user=$USER_N role=$ROLE"

# RESILIENT-320 AC2: no hand-placed worker caps — the installer writes CHUMP_ORCH_WORKER_MAX
# itself (node-orchestrator.sh sources cj.env and honors it). factory only.
# UPSERT only: cj.env may already hold live credentials (OAuth/GH) on a real node
# (write_runner sources it alongside providers.env) — never truncate the whole file.
if [ "$ROLE" = factory ]; then
  [ -z "$WORKER_MAX" ] && WORKER_MAX=$(( $(nproc 2>/dev/null || echo 2) - 1 )); [ "$WORKER_MAX" -lt 1 ] && WORKER_MAX=1
  if [ "$DRY" = 1 ]; then
    echo "  DRY: upsert CHUMP_ORCH_WORKER_MAX=$WORKER_MAX -> $STATE/cj.env"
  else
    touch "$STATE/cj.env"
    grep -v '^CHUMP_ORCH_WORKER_MAX=' "$STATE/cj.env" > "$STATE/cj.env.tmp" || true
    printf 'CHUMP_ORCH_WORKER_MAX=%s\n' "$WORKER_MAX" >> "$STATE/cj.env.tmp"
    mv "$STATE/cj.env.tmp" "$STATE/cj.env"
    log "upserted CHUMP_ORCH_WORKER_MAX=$WORKER_MAX -> $STATE/cj.env"
  fi
fi

# full organ table: name|repo-relative-script[ args]|cadence-seconds|roles-csv (0 cadence = self-loops)
ORGANS_ALL="node-orchestrator|scripts/ops/node-orchestrator.sh|0|factory,data,embed
disk-monitor|scripts/ops/disk-health-monitor.sh|300|factory,data,embed
main-health-watchdog|scripts/ops/main-health-watchdog.sh|600|factory,data
rot-reaper|scripts/ops/rot-reaper.sh|1800|factory
worktree-reaper|scripts/ops/stale-worktree-reaper.sh --execute|900|factory
pr-lander|scripts/dispatch/pr-lander-beat.sh|600|factory
cargo-sweep-gc|scripts/ops/cargo-sweep-gc.sh|3600|factory"

# filter to this role's organs (AC1 — data/embed never get pr-lander/reapers)
ORGANS=""
while IFS='|' read -r name script cadence roles; do
  [ -z "$name" ] && continue
  case ",$roles," in *",$ROLE,"*) ORGANS="$ORGANS
$name|$script|$cadence";; esac
done <<EOF
$ORGANS_ALL
EOF
ORGANS="$(printf '%s\n' "$ORGANS" | sed '/^$/d')"

# write the self-contained loop-runner for an organ (sources creds, sets PATH, loops at cadence)
write_runner() {
  local name="$1" script="$2" cadence="$3"
  [ "$DRY" = 1 ] && { echo "  DRY: write $STATE/organs/$name.sh (script=$script cadence=$cadence)"; return 0; }
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
  [ "$DRY" = 1 ] && { echo "  DRY: install systemd unit chump-$name.service"; return 0; }
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
  [ "$DRY" = 1 ] && { echo "  DRY: install runit service chump-$name"; return 0; }
  mkdir -p "$SVDIR/chump-$name/log"
  printf '#!/data/data/com.termux/files/usr/bin/sh\nexec 2>&1\nexec bash %s\n' "$STATE/organs/$name.sh" > "$SVDIR/chump-$name/run"
  chmod +x "$SVDIR/chump-$name/run"
  printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s\n' "$STATE/organs/logs/$name" > "$SVDIR/chump-$name/log/run"
  chmod +x "$SVDIR/chump-$name/log/run"; mkdir -p "$STATE/organs/logs/$name"
}

# reconcile: retire any older hand-installed timer/service variants so we don't double-run
if [ "$SUP" = systemd ] && [ "$DRY" != 1 ]; then
  for old in chump-rot-reaper.timer chump-worktree-reaper.timer chump-cj-disk-monitor.service; do
    sudo systemctl disable --now "$old" >/dev/null 2>&1 || true
  done
  # RESILIENT-320 AC3: role reconcile — a data/embed node must NEVER run pr-lander or
  # the PR-reapers, even if a prior full (role-blind) install left them hand-placed.
  if [ "$ROLE" != factory ]; then
    for off in pr-lander rot-reaper worktree-reaper cargo-sweep-gc; do
      systemctl is-active "chump-$off.service" >/dev/null 2>&1 && {
        sudo systemctl disable --now "chump-$off.service" >/dev/null 2>&1 || true
        log "reconciled off (role=$ROLE): chump-$off"
      }
    done
  fi
elif [ "$DRY" = 1 ] && [ "$ROLE" != factory ]; then
  echo "  DRY: would reconcile off pr-lander/rot-reaper/worktree-reaper/cargo-sweep-gc if present (role=$ROLE)"
fi

while IFS='|' read -r name script cadence; do
  [ -z "$name" ] && continue
  write_runner "$name" "$script" "$cadence"
  case "$SUP" in
    systemd) install_systemd "$name" ;;
    runit)   install_runit "$name"; [ "$DRY" = 1 ] || sv up "$SVDIR/chump-$name" 2>/dev/null || true ;;
    *)       [ "$DRY" = 1 ] || nohup bash "$STATE/organs/$name.sh" >/dev/null 2>&1 & ;;
  esac
  log "installed + up: chump-$name"
done <<EOF
$ORGANS
EOF
[ "$SUP" = systemd ] && [ "$DRY" != 1 ] && sudo systemctl daemon-reload

# integrator (factory only, best-effort — separate binary/install path, systemd+root)
if [ "$ROLE" = factory ] && [ "$SUP" = systemd ]; then
  if [ "$DRY" = 1 ]; then
    log "DRY: would install chump-integrator (needs root)"
  elif [ -x "$REPO/scripts/setup/install-integrator-daemon-systemd.sh" ] && [ "$(id -u)" = 0 ]; then
    bash "$REPO/scripts/setup/install-integrator-daemon-systemd.sh" >/dev/null 2>&1 \
      && log "installed + up: chump-integrator (dry-run by default; --live to arm)" \
      || log "integrator install skipped (non-fatal — run install-integrator-daemon-systemd.sh manually)"
  else
    log "integrator install skipped (needs root; run scripts/setup/install-integrator-daemon-systemd.sh manually)"
  fi
fi

# self-test — role-filtered organ list, so a data/embed node's self-test never checks for pr-lander
log "self-test (role=$ROLE):"
fail=0
echo "$ORGANS" | while IFS='|' read -r name _ _; do
  [ -z "$name" ] && continue
  case "$SUP" in
    systemd) systemctl is-active "chump-$name.service" >/dev/null 2>&1 && log "  ✓ $name up" || { log "  ✗ $name DOWN"; exit 1; } ;;
    runit)   sv status "$SVDIR/chump-$name" 2>/dev/null | grep -q '^run' && log "  ✓ $name up" || { log "  ✗ $name DOWN"; exit 1; } ;;
  esac
done || fail=1
[ -f "$STATE/resource-inventory.json" ] && log "  ✓ orchestrator sensing (resource-inventory.json present)" || log "  … inventory not written yet (orchestrator warming up)"
if [ "$ROLE" = data ]; then
  if command -v pg_isready >/dev/null 2>&1 && pg_isready >/dev/null 2>&1; then log "  ✓ postgres up"
  elif systemctl is-active postgresql >/dev/null 2>&1; then log "  ✓ postgres up (systemd)"
  else log "  … postgres not detected (install/point-at Postgres separately — see docs/strategy/DATA_HOME_PLAN.md)"; fi
fi
[ "$fail" = 0 ] && log "HOUSEKEEPING INSTALLED ✓ (role=$ROLE) — node self-manages" || { log "some organs down — check logs"; exit 1; }
