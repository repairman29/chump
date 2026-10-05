#!/usr/bin/env bash
# spawn-worker-fleet.sh — INFRA-471 / hardware-aware self-organization.
#
# THE PROBLEM this exists to fix (2026-09-11): a node ran a SINGLE worker with
# FLEET_MODEL=sonnet on a 1907-gap backlog. The picker's model-class gate
# (_pick_and_claim_gap.py, INFRA-471) makes a sonnet worker REFUSE effort=xs —
# so the 883 xs gaps (46% of the open backlog) were invisible to the only
# worker on the box, and the fleet starved while work sat pickable. Two root
# causes, one tool:
#
#   1. RIGHT-MODEL-CLASS. One node needs BOTH a haiku-class instance (eats xs)
#      AND sonnet-class instances (eat s,m,l) — otherwise a whole effort band
#      is unpickable. This renders one launcher per instance with its own
#      FLEET_MODEL + FLEET_EFFORT_FILTER from a tracked template, so the mix is
#      reproducible and reviewable, never hand-set on the node.
#   2. PARALLELISM. A single picker can't drain thousands of gaps. This sizes
#      the instance count to the node's cores (a 2-core Oracle box gets few, an
#      8-core Pixel many), so the backlog gets many pickers.
#
# Reproducible mechanism, NOT a hand-edited node file: every instance's launcher
# is rendered from scripts/dispatch/worker-launcher.template.sh (the tracked,
# node-neutral RESILIENT-1099 template) and each systemd unit is generated here.
# Re-running is idempotent (same inputs -> same launchers + units).
#
# USAGE (run ON the node, from its chump checkout):
#   bash scripts/dispatch/spawn-worker-fleet.sh              # dry-run: show plan
#   bash scripts/dispatch/spawn-worker-fleet.sh --apply      # render + enable
#   bash scripts/dispatch/spawn-worker-fleet.sh --print-units # emit unit files
#
# KNOBS (env):
#   CHUMP_WORKER_COUNT        instances to run (default: cores-1, capped at 8)
#   CHUMP_WORKER_MODEL_MIX    "class:effortcsv;..." assigned round-robin.
#                             default: "haiku:xs;sonnet:s,m,l" — guarantees the
#                             first instance is a haiku/xs xs-eater.
#   CHUMP_WORKER_AGENT_PREFIX agent-id prefix (default: <hostname>-worker)
#   CHUMP_WORKER_MACHINE      machine label      (default: <hostname>)
#   CHUMP_WORKER_SESSION      session tag        (default: machine label)
#   CHUMP_WORKER_SKILLS       csv skill tags     (default: empty = any)
#   CHUMP_WORKER_DOMAIN_FILTER csv domain filter (default: empty = any)
#   CHUMP_ORGAN_DIR           where launchers land (default: $HOME/.chump/organs)
#   CHUMP_REPO / REPO_ROOT    node's chump checkout (default: git toplevel)
set -uo pipefail

MODE="dry"
case "${1:-}" in
  --apply)       MODE="apply" ;;
  --print-units) MODE="print-units" ;;
  ""|--dry|--dry-run) MODE="dry" ;;
  -h|--help)
    sed -n '2,40p' "$0"; exit 0 ;;
  *) echo "unknown arg: $1 (use --apply | --print-units | --dry-run)" >&2; exit 2 ;;
esac

# ── resolve node context ────────────────────────────────────────────────────
REPO_ROOT="${CHUMP_REPO:-${REPO_ROOT:-}}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
fi
TEMPLATE="$REPO_ROOT/scripts/dispatch/worker-launcher.template.sh"
if [ ! -f "$TEMPLATE" ]; then
  echo "FATAL: launcher template not found: $TEMPLATE" >&2
  exit 1
fi

HOSTNAME_S="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)"
AGENT_PREFIX="${CHUMP_WORKER_AGENT_PREFIX:-${HOSTNAME_S}-worker}"
MACHINE="${CHUMP_WORKER_MACHINE:-$HOSTNAME_S}"
SESSION="${CHUMP_WORKER_SESSION:-$MACHINE}"
SKILLS="${CHUMP_WORKER_SKILLS:-}"
DOMAIN="${CHUMP_WORKER_DOMAIN_FILTER:-}"
ORGAN_DIR="${CHUMP_ORGAN_DIR:-$HOME/.chump/organs}"
RUN_USER="${CHUMP_WORKER_RUN_USER:-$(id -un 2>/dev/null || echo root)}"

# ── size the fleet to the node's cores ──────────────────────────────────────
detect_cores() {
  local n=""
  n="$(nproc 2>/dev/null || true)"
  [ -z "$n" ] && n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [ -z "$n" ] && n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  echo "$n"
}
CORES="$(detect_cores)"
WORKER_CAP="${CHUMP_WORKER_CAP:-8}"
if [ -n "${CHUMP_WORKER_COUNT:-}" ]; then
  COUNT="$CHUMP_WORKER_COUNT"
else
  # Reserve one core for the OS + organs; never fewer than 1, never more than cap.
  COUNT=$(( CORES - 1 ))
  [ "$COUNT" -lt 1 ] && COUNT=1
  [ "$COUNT" -gt "$WORKER_CAP" ] && COUNT="$WORKER_CAP"
fi
case "$COUNT" in ''|*[!0-9]*) echo "FATAL: bad worker count '$COUNT'" >&2; exit 1 ;; esac

# ── model-class + effort mix (round-robin across instances) ─────────────────
MODEL_MIX="${CHUMP_WORKER_MODEL_MIX:-haiku:xs;sonnet:s,m,l}"
# Split on ';' into MIX_ENTRIES[] without associative arrays (bash 3.2 safe).
OLD_IFS="$IFS"; IFS=';'
# shellcheck disable=SC2206
MIX_ENTRIES=( $MODEL_MIX )
IFS="$OLD_IFS"
MIX_N="${#MIX_ENTRIES[@]}"
if [ "$MIX_N" -eq 0 ]; then
  echo "FATAL: empty CHUMP_WORKER_MODEL_MIX" >&2; exit 1
fi

# entry_model / entry_effort split "class:effortcsv"
entry_model()  { printf '%s' "${1%%:*}"; }
entry_effort() { local e="${1#*:}"; [ "$e" = "$1" ] && e="xs,s,m"; printf '%s' "$e"; }

render_launcher() { # $1=agent_id $2=model $3=effort  -> writes $ORGAN_DIR/worker-<agent_id>.sh
  local agent_id="$1" model="$2" effort="$3" out="$ORGAN_DIR/worker-$1.sh"
  sed \
    -e "s|__AGENT_ID__|$agent_id|g" \
    -e "s|__WORKER_MACHINE__|$MACHINE|g" \
    -e "s|__FLEET_SESSION__|$SESSION|g" \
    -e "s|__WORKER_SKILLS__|$SKILLS|g" \
    -e "s|__FLEET_DOMAIN_FILTER__|$DOMAIN|g" \
    -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
    -e "s|__FLEET_MODEL__|$model|g" \
    -e "s|__FLEET_EFFORT_FILTER__|$effort|g" \
    "$TEMPLATE" > "$out"
  chmod +x "$out"
  printf '%s' "$out"
}

unit_text() { # $1=agent_id $2=launcher_path -> systemd unit body
  local agent_id="$1" launcher="$2"
  cat <<UNIT
[Unit]
Description=Chump fleet worker $agent_id (INFRA-471 model-class instance)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/env bash $launcher
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
UNIT
}

# ── build the plan (pure — no side effects) ─────────────────────────────────
i=1
PLAN=""          # lines: agent_id<TAB>model<TAB>effort
while [ "$i" -le "$COUNT" ]; do
  idx=$(( (i - 1) % MIX_N ))
  entry="${MIX_ENTRIES[$idx]}"
  m="$(entry_model "$entry")"
  e="$(entry_effort "$entry")"
  PLAN="${PLAN}${AGENT_PREFIX}-${i}	${m}	${e}
"
  i=$(( i + 1 ))
done

echo "=== spawn-worker-fleet.sh (INFRA-471) ==="
echo "  node        : $MACHINE  (cores=$CORES)"
echo "  repo        : $REPO_ROOT"
echo "  organ dir   : $ORGAN_DIR"
echo "  run user    : $RUN_USER"
echo "  worker count: $COUNT   (cap=$WORKER_CAP)"
echo "  model mix   : $MODEL_MIX"
echo "  mode        : $MODE"
echo "  --- planned instances ---"
printf '%s' "$PLAN" | while IFS='	' read -r aid m e; do
  [ -z "$aid" ] && continue
  printf '    %-24s model=%-7s effort=%s\n' "$aid" "$m" "$e"
done

# ── print-units: emit unit files to stdout, no writes ───────────────────────
if [ "$MODE" = "print-units" ]; then
  echo "  --- systemd units (not written; pipe/copy to /etc/systemd/system) ---"
  printf '%s' "$PLAN" | while IFS='	' read -r aid m e; do
    [ -z "$aid" ] && continue
    echo "# ==> /etc/systemd/system/chump-$aid.service"
    unit_text "$aid" "$ORGAN_DIR/worker-$aid.sh"
    echo
  done
  exit 0
fi

# ── dry-run: show what --apply WOULD do, then stop ──────────────────────────
if [ "$MODE" = "dry" ]; then
  echo
  echo "  DRY-RUN — nothing written. To stand these up on THIS node, run:"
  echo "    sudo CHUMP_WORKER_MODEL_MIX='$MODEL_MIX' bash scripts/dispatch/spawn-worker-fleet.sh --apply"
  echo "  (or preview the unit files with:  bash scripts/dispatch/spawn-worker-fleet.sh --print-units )"
  exit 0
fi

# ── apply: render launchers + install units + enable ────────────────────────
mkdir -p "$ORGAN_DIR" 2>/dev/null || { echo "FATAL: cannot mkdir $ORGAN_DIR" >&2; exit 1; }

# Where do units go? Prefer system units if writable (matches the existing
# chump-node1-worker.service), else fall back to per-user systemd.
UNIT_DIR="/etc/systemd/system"
SYSTEMCTL="systemctl"
USER_SCOPE=0
if [ ! -w "$UNIT_DIR" ]; then
  if systemctl --user show-environment >/dev/null 2>&1; then
    UNIT_DIR="$HOME/.config/systemd/user"
    SYSTEMCTL="systemctl --user"
    USER_SCOPE=1
    mkdir -p "$UNIT_DIR"
    echo "  NOTE: /etc/systemd/system not writable — installing as USER units in $UNIT_DIR"
  else
    echo "FATAL: cannot write $UNIT_DIR and no user systemd available." >&2
    echo "       Re-run with sudo, or use --print-units and install by hand." >&2
    exit 1
  fi
fi

printf '%s' "$PLAN" | while IFS='	' read -r aid m e; do
  [ -z "$aid" ] && continue
  launcher="$(render_launcher "$aid" "$m" "$e")"
  echo "  rendered $launcher (model=$m effort=$e)"
  unit_path="$UNIT_DIR/chump-$aid.service"
  unit_text "$aid" "$launcher" > "$unit_path"
  echo "  wrote    $unit_path"
done

$SYSTEMCTL daemon-reload 2>/dev/null || true
printf '%s' "$PLAN" | while IFS='	' read -r aid m e; do
  [ -z "$aid" ] && continue
  if $SYSTEMCTL enable --now "chump-$aid.service" >/dev/null 2>&1; then
    echo "  enabled  chump-$aid.service"
  else
    echo "  WARN could not enable chump-$aid.service (enable it manually)"
  fi
done

echo
echo "DONE. Verify with:  $SYSTEMCTL --no-pager --type=service | grep chump-$AGENT_PREFIX"
[ "$USER_SCOPE" = 1 ] && echo "NOTE: user units stop at logout unless 'loginctl enable-linger $RUN_USER' is set."
exit 0
