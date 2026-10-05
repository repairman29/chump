#!/usr/bin/env bash
# install-index-almanac-timer.sh — RESILIENT-404 (RESILIENT-367 slice)
#
# Wires scripts/ops/index-almanac.sh (the fleet-wide ollama nomic-embed-text
# reindex sweep) into supervision on the factory node: an hourly timer plus
# a path-triggered unit that fires the same sweep the moment a new repo
# checkout appears under the scan root (AC2 "also triggers on new repo
# discovery"). Mirrors install-almanac-organ.sh's supervisor detection
# (systemd --user timer > launchd agent > cron fallback) but is standalone
# — it doesn't source chump-node-install.sh, since this organ needs no
# toolchain preflight (it only shells out to an already-built almanac CLI).
#
# AC3 ("runs entirely on the factory node, not on the Mac"): this installer
# is a no-op refusal on macOS — almanac's data-gravity problem
# (docs/design/FLEET_LOAD_MAP.md) is exactly the Mac-resident-index anti-
# pattern this gap exists to move off of, so install here is Linux-only by
# design, not by oversight.
#
# Usage:
#   scripts/setup/install-index-almanac-timer.sh              # install + run once now
#   scripts/setup/install-index-almanac-timer.sh --check       # verify only, exit non-zero if incomplete
#   scripts/setup/install-index-almanac-timer.sh --dry-run
#
# Env:
#   CHUMP_STATE_DIR   chump state dir, for logs (default: $HOME/.chump)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INDEX_SCRIPT="$REPO_ROOT/scripts/ops/index-almanac.sh"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
LOG_DIR="$STATE_DIR/logs"

MODE="install"; DRY=0
for a in "$@"; do
  case "$a" in
    --check) MODE="check" ;;
    --dry-run) DRY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[INDEX-ALMANAC]\033[0m %s\n' "$*"; }
run(){ [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

LABEL="com.chump.index-almanac"
SERVICE_NAME="chump-index-almanac.service"
TIMER_NAME="chump-index-almanac.timer"
PATH_NAME="chump-index-almanac.path"
WATCH_DIR="${ALMANAC_FLEET_ROOTS:-$HOME/Projects}"

if [ "$(uname -s)" = "Darwin" ]; then
  no "this organ is Linux-factory-only by design (AC3) — refusing on macOS"
  exit 1
fi

if [ ! -x "$INDEX_SCRIPT" ]; then
  no "index script missing or not executable: $INDEX_SCRIPT"
  exit 1
fi

detect_supervisor() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    echo "systemd-user"
  elif command -v crontab >/dev/null 2>&1; then
    echo "cron"
  else
    echo "none"
  fi
}

install_systemd_user() {
  local unit_dir="$HOME/.config/systemd/user"
  run "mkdir -p '$unit_dir' '$LOG_DIR'"
  run "cat > '$unit_dir/$SERVICE_NAME' <<EOF
[Unit]
Description=Chump almanac fleet reindex — ollama nomic-embed-text sweep (RESILIENT-404)

[Service]
Type=oneshot
Environment=CHUMP_REPO_ROOT=$REPO_ROOT
Environment=ALMANAC_FLEET_ROOTS=$WATCH_DIR
ExecStart=$INDEX_SCRIPT
EOF"
  run "cat > '$unit_dir/$TIMER_NAME' <<EOF
[Unit]
Description=Chump almanac fleet reindex beat — hourly (RESILIENT-404)

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF"
  run "cat > '$unit_dir/$PATH_NAME' <<EOF
[Unit]
Description=Chump almanac fleet reindex — trigger on new repo discovery (RESILIENT-404)

[Path]
PathModified=$WATCH_DIR
Unit=$SERVICE_NAME

[Install]
WantedBy=paths.target
EOF"
  run "systemctl --user daemon-reload"
  run "systemctl --user enable --now '$TIMER_NAME'"
  run "systemctl --user enable --now '$PATH_NAME'"
  ok "systemd --user timer installed: $TIMER_NAME (hourly) + $PATH_NAME (watching $WATCH_DIR)"
}

install_cron() {
  run "mkdir -p '$LOG_DIR'"
  local marker="# chump-index-almanac (RESILIENT-404)"
  local line="0 * * * * CHUMP_REPO_ROOT=$REPO_ROOT ALMANAC_FLEET_ROOTS=$WATCH_DIR $INDEX_SCRIPT >> $LOG_DIR/index-almanac.log 2>&1 $marker"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: crontab -l | grep -v '$marker' ; append: $line"
  else
    ( crontab -l 2>/dev/null | grep -vF "$marker"; echo "$line" ) | crontab -
  fi
  ok "cron fallback installed: hourly ($marker) — no new-repo-discovery trigger available under cron"
}

do_install() {
  local sup; sup="$(detect_supervisor)"
  info "supervisor=$sup"
  case "$sup" in
    systemd-user) install_systemd_user ;;
    cron) install_cron ;;
    *) no "no supervisor available (systemd --user, cron) — organ not supervised; run $INDEX_SCRIPT by hand"; return 1 ;;
  esac
  info "running index sweep once now"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: $INDEX_SCRIPT"
  else
    CHUMP_REPO_ROOT="$REPO_ROOT" ALMANAC_FLEET_ROOTS="$WATCH_DIR" "$INDEX_SCRIPT" || true
  fi
}

do_check() {
  local fail=0
  local sup; sup="$(detect_supervisor)"
  case "$sup" in
    systemd-user)
      if systemctl --user is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
        ok "systemd --user timer enabled: $TIMER_NAME"
      else no "systemd --user timer NOT enabled: $TIMER_NAME"; fail=1; fi
      if systemctl --user is-enabled "$PATH_NAME" >/dev/null 2>&1; then
        ok "systemd --user path unit enabled: $PATH_NAME"
      else no "systemd --user path unit NOT enabled: $PATH_NAME"; fail=1; fi
      ;;
    cron)
      if crontab -l 2>/dev/null | grep -q "chump-index-almanac"; then ok "cron entry present"
      else no "cron entry missing"; fail=1; fi
      ;;
    *) no "no supervisor available"; fail=1 ;;
  esac
  return "$fail"
}

if [ "$MODE" = "check" ]; then
  do_check
  exit $?
else
  do_install
  exit $?
fi
