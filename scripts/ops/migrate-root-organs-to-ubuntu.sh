#!/usr/bin/env bash
# scripts/ops/migrate-root-organs-to-ubuntu.sh — RESILIENT-1687
#
# Migrate the two live ROOT organs off the /root/.chumpnode install onto
# User=ubuntu running the tracked repo copies under /home/ubuntu/chump:
#     chump-fleet-health-sentinel.service   (scripts/ops/fleet-health-sentinel.sh)
#     chump-node-heartbeat.service          (scripts/ops/node-heartbeat.sh)
#
# WHAT IT DOES. Renders a systemd drop-in for EXACTLY those two units that:
#   * sets User=ubuntu (the root-write trap: a unit with no User ran as root and
#     wrote /root/.chump — or /.chump with no HOME — which ubuntu can't read);
#   * clears the inherited ExecStart and points it at the repo copy under the
#     repo root (default /home/ubuntu/chump), run via /usr/bin/env bash;
#   * loads providers.env from the ubuntu home.
# It then lists every STATE FILE the two organ scripts write (parsed FROM THE
# SCRIPTS, resolved against the ubuntu home) and chowns them to ubuntu so the
# migrated units keep writing. A dry-run prints the drop-ins, the chown list,
# and the apply commands and changes NOTHING.
#
# SAFETY-INPUT SEAM (STANDING RULE, Chief 2026-10-20). The home, user, repo
# root, and drop-in root are resolved from explicit CLI args with production
# defaults — NEVER from a CHUMP_* env default, which is a safety-input bypass
# by construction. systemd units never invoke this renderer, so there is no
# unit that could inject those args. Tests pass the fixture paths as CLI args.
#
# APPLY is operator-only (needs sudo) and is a SEPARATE step after this PR
# lands — the PR itself never runs sudo. --apply renders, daemon-reloads,
# restarts EXACTLY the two units, verifies User=ubuntu + a fresh heartbeat
# within one 60s interval, and logs the receipt to ~/.chump/paused-timers.txt
# (un-pause item 8).
set -uo pipefail

# ── defaults (production target: cuphead's ubuntu account) ───────────────────
HOME_DIR="/home/ubuntu"
RUN_USER="ubuntu"
REPO_ROOT="/home/ubuntu/chump"
DROPIN_ROOT="/etc/systemd/system"
MODE="dry-run"          # dry-run | render-dropin | chown-list | apply
RENDER_UNIT=""

# The exact two units this migration touches, mapped to their repo script +
# ExecStart argv. Keyed by the systemd unit basename (no .service).
_unit_script() {
  case "$1" in
    chump-node-heartbeat)        printf 'scripts/ops/node-heartbeat.sh' ;;
    chump-fleet-health-sentinel) printf 'scripts/ops/fleet-health-sentinel.sh' ;;
    *) return 1 ;;
  esac
}
_unit_execargs() {
  case "$1" in
    chump-node-heartbeat)        printf '' ;;
    chump-fleet-health-sentinel) printf -- '--local --loop' ;;
    *) return 1 ;;
  esac
}
UNITS=(chump-fleet-health-sentinel chump-node-heartbeat)

die() { echo "migrate-root-organs: $*" >&2; exit 2; }

# ── state-path extraction: read the write targets FROM THE SCRIPTS ───────────
# Resolve every state file the organ script writes against <home>/.chump (plus
# any fixed /tmp heartbeat sink). We parse the script's own redirections and
# heartbeat-file assignments so the chown list tracks the scripts, not a
# hand-maintained duplicate list that would silently drift.
_state_paths_for_script() {
  local script="$1" state="$2/.chump"
  [ -f "$script" ] || die "organ script not found: $script"
  # grep returning 1 on no-match is expected per pattern; `|| true` keeps it from
  # tripping pipefail when a given organ writes no path of that shape.
  {
    # (a) redirections into $STATE / $STATE_DIR  (e.g.  > "$STATE/node-heartbeat")
    { grep -oE '>[[:space:]]*"\$\{?(STATE|STATE_DIR)\}?/[A-Za-z0-9._-]+"' "$script" || true; } \
      | sed -E 's/.*\/([A-Za-z0-9._-]+)"$/\1/' \
      | while IFS= read -r n; do [ -n "$n" ] && printf '%s/%s\n' "$state" "$n"; done
    # (b) *_FILE / *_HB assignments bound to a $STATE_DIR-rooted path
    { grep -oE '="\$\{?STATE_DIR\}?/[A-Za-z0-9._-]+"' "$script" || true; } \
      | sed -E 's/.*\/([A-Za-z0-9._-]+)"$/\1/' \
      | while IFS= read -r n; do [ -n "$n" ] && printf '%s/%s\n' "$state" "$n"; done
    # (c) fixed /tmp heartbeat sinks (REAPER_HB and friends)
    { grep -oE '"/tmp/chump-[A-Za-z0-9._-]+\.heartbeat"' "$script" || true; } | tr -d '"'
  } | sort -u
}

# Every state path both organs write, resolved + deduped.
chown_list() {
  local u script
  for u in "${UNITS[@]}"; do
    script="$REPO_ROOT/$(_unit_script "$u")"
    _state_paths_for_script "$script" "$HOME_DIR"
  done | sort -u
}

# ── drop-in rendering ────────────────────────────────────────────────────────
render_dropin() {
  local u="$1"
  local script execargs exec_line
  script="$(_unit_script "$u")" || die "not one of the two migration units: $u"
  execargs="$(_unit_execargs "$u")"
  exec_line="/usr/bin/env bash $REPO_ROOT/$script"
  [ -n "$execargs" ] && exec_line="$exec_line $execargs"
  cat <<EOF
[Service]
# RESILIENT-1687: migrate $u off the /root/.chumpnode install onto
# User=$RUN_USER running the tracked repo copy. Drop-in overrides the root unit.
User=$RUN_USER
Group=$RUN_USER
EnvironmentFile=-$HOME_DIR/.chump/providers.env
ExecStart=
ExecStart=$exec_line
EOF
}

# ── dry-run report ───────────────────────────────────────────────────────────
dry_run() {
  local u p
  echo "== RESILIENT-1687 migration (DRY-RUN — nothing is changed) =="
  echo "   home=$HOME_DIR user=$RUN_USER repo=$REPO_ROOT dropin-root=$DROPIN_ROOT"
  echo
  for u in "${UNITS[@]}"; do
    echo "--- drop-in: $DROPIN_ROOT/$u.service.d/90-resilient-1687-ubuntu.conf ---"
    render_dropin "$u"
    echo
  done
  echo "--- state paths to chown to $RUN_USER (parsed from the organ scripts) ---"
  chown_list
  echo
  echo "--- apply commands (operator runs with sudo; this PR never does) ---"
  for u in "${UNITS[@]}"; do
    echo "  install -D -m644 <rendered> $DROPIN_ROOT/$u.service.d/90-resilient-1687-ubuntu.conf"
  done
  while IFS= read -r p; do echo "  chown $RUN_USER:$RUN_USER $p   # (only if it exists)"; done < <(chown_list)
  echo "  systemctl daemon-reload"
  echo "  systemctl restart ${UNITS[*]/%/.service}"
}

# ── apply (operator-only; needs sudo/root) ───────────────────────────────────
apply() {
  local u conf script state p now_before hb_file
  [ "$(id -u)" = 0 ] || die "--apply must run as root (sudo); this is the operator un-pause step"
  for u in "${UNITS[@]}"; do
    conf="$DROPIN_ROOT/$u.service.d/90-resilient-1687-ubuntu.conf"
    mkdir -p "$DROPIN_ROOT/$u.service.d"
    render_dropin "$u" > "$conf"
    echo "wrote $conf"
  done
  # chown each state path that already exists; create the state dir owned by user.
  install -d -o "$RUN_USER" -g "$RUN_USER" "$HOME_DIR/.chump"
  while IFS= read -r p; do
    if [ -e "$p" ]; then chown "$RUN_USER:$RUN_USER" "$p" && echo "chowned $p"; fi
  done < <(chown_list)
  systemctl daemon-reload
  # restart EXACTLY the two units
  systemctl restart "${UNITS[@]/%/.service}"
  # verify User=ubuntu on both, and a fresh node-heartbeat write within one interval.
  for u in "${UNITS[@]}"; do
    systemctl show -p User --value "$u.service" | grep -qx "$RUN_USER" \
      || die "verify failed: $u.service is not User=$RUN_USER after restart"
  done
  hb_file="$HOME_DIR/.chump/node-heartbeat"
  now_before="$(date -u +%s)"
  local ok=0 i
  for i in $(seq 1 70); do
    if [ -f "$hb_file" ]; then
      local mt; mt="$(date -u -r "$hb_file" +%s 2>/dev/null || stat -c %Y "$hb_file" 2>/dev/null || echo 0)"
      [ "$mt" -ge "$now_before" ] && { ok=1; break; }
    fi
    sleep 1
  done
  [ "$ok" = 1 ] || die "verify failed: no fresh $hb_file write within 70s (one 60s interval)"
  # receipt → un-pause item 8
  printf '[%s] RESILIENT-1687 un-pause: migrated chump-fleet-health-sentinel + chump-node-heartbeat to User=%s; fresh node-heartbeat verified. item 8 CLEAR.\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_USER" >> "$HOME_DIR/.chump/paused-timers.txt"
  echo "apply complete; receipt appended to $HOME_DIR/.chump/paused-timers.txt"
}

# ── args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)        HOME_DIR="$2"; shift ;;
    --user)        RUN_USER="$2"; shift ;;
    --repo)        REPO_ROOT="$2"; shift ;;
    --dropin-root) DROPIN_ROOT="$2"; shift ;;
    --dry-run)     MODE="dry-run" ;;
    --apply)       MODE="apply" ;;
    --chown-list)  MODE="chown-list" ;;
    --render-dropin) MODE="render-dropin"; RENDER_UNIT="${2:-}"; shift ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

case "$MODE" in
  dry-run)       dry_run ;;
  chown-list)    chown_list ;;
  render-dropin) [ -n "$RENDER_UNIT" ] || die "--render-dropin needs a unit name"
                 render_dropin "${RENDER_UNIT%.service}" ;;
  apply)         apply ;;
esac
