#!/usr/bin/env bash
# scripts/ops/nats-deploy.sh — INFRA-8065 (merged-not-running: nats/ cloud kit).
#
# Deploys the nats/ cloud-agent kit from chump-proprietary main onto the hub
# (cuphead) and proves installed == main. Root cause it closes: nothing pulled
# nats/ onto the hub, so the dispatcher uncap (DISPATCH_MAX_PER_DAY default 0)
# sat undeployed for a day while the hub kept running the capped copy.
#
# Modes:
#   (default)  fetch main, install changed files, restart fleet-dispatch.service
#              if its code/unit changed, strip any hard-pinned per-day cap from
#              the unit, then verify the receipt (installed sha == main).
#   --check    read-only drift check: exits 1 + emits kind=nats_deploy_drift
#              when any tracked file's installed sha != main (the pager).
#
# Env:
#   NATS_DEPLOY_REPO       git URL of chump-proprietary (default git@github.com:repairman29/chump-proprietary.git)
#   NATS_DEPLOY_SRC_DIR    local source tree to use instead of cloning (test hook; must be the nats/ dir)
#   NATS_AGENTS_HOME       install root (default $HOME/.local/share/nats-agents)
#   NATS_DEPLOY_CACHE      clone cache (default $HOME/.cache/nats-deploy)
#   NATS_DEPLOY_SERVICE    unit to restart (default fleet-dispatch.service)
#   NATS_DEPLOY_UNIT_FILE  unit file to de-pin (default /etc/systemd/system/$NATS_DEPLOY_SERVICE)
#   NATS_DEPLOY_NO_SYSTEMCTL=1  skip systemctl calls (tests)
#   CHUMP_REPO_ROOT       for ambient emit (default: this script's repo)
set -euo pipefail

MODE=deploy
[[ "${1:-}" == "--check" ]] && MODE=check

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
REPO_URL="${NATS_DEPLOY_REPO:-git@github.com:repairman29/chump-proprietary.git}"
DEST="${NATS_AGENTS_HOME:-$HOME/.local/share/nats-agents}"
CACHE="${NATS_DEPLOY_CACHE:-$HOME/.cache/nats-deploy}"
SERVICE="${NATS_DEPLOY_SERVICE:-fleet-dispatch.service}"
UNIT_FILE="${NATS_DEPLOY_UNIT_FILE:-/etc/systemd/system/$SERVICE}"
TRACKED=(fleet_dispatch.py nats_bus_mcp.py nats_agents.py)

emit() {
  local kind="$1"; shift
  local e="$REPO_ROOT/scripts/dev/ambient-emit.sh"
  [[ -x "$e" ]] && "$e" "$kind" "$@" >/dev/null 2>&1 || true
}
sha() { sha256sum "$1" | cut -c1-12; }
sysctl() { [[ "${NATS_DEPLOY_NO_SYSTEMCTL:-0}" == 1 ]] || systemctl "$@"; }

if [[ -n "${NATS_DEPLOY_SRC_DIR:-}" ]]; then
  SRC="$NATS_DEPLOY_SRC_DIR"; MAIN_REV="local"
else
  mkdir -p "$CACHE"
  if [[ ! -d "$CACHE/repo/.git" ]]; then
    git clone --quiet --depth 1 "$REPO_URL" "$CACHE/repo"
  else
    git -C "$CACHE/repo" fetch --quiet --depth 1 origin main
    git -C "$CACHE/repo" reset --quiet --hard FETCH_HEAD
  fi
  SRC="$CACHE/repo/nats"; MAIN_REV="$(git -C "$CACHE/repo" rev-parse --short HEAD)"
fi
[[ -d "$SRC" ]] || { echo "nats-deploy: source dir $SRC missing" >&2; exit 2; }

# Relative paths under nats/ of the tracked files (layout preserved on install).
tracked_rel=()
for n in "${TRACKED[@]}"; do
  p="$(cd "$SRC" && find . -name "$n" -type f | head -1 | sed 's|^\./||')"
  [[ -n "$p" ]] || { echo "nats-deploy: $n not found in $SRC" >&2; exit 2; }
  tracked_rel+=("$p")
done

drift=()
for r in "${tracked_rel[@]}"; do
  [[ -f "$DEST/$r" && "$(sha "$SRC/$r")" == "$(sha "$DEST/$r")" ]] || drift+=("$r")
done

if [[ "$MODE" == check ]]; then
  if ((${#drift[@]})); then
    echo "nats-deploy: DRIFT vs main@$MAIN_REV: ${drift[*]}" >&2
    emit nats_deploy_drift main="$MAIN_REV" files="$(IFS=,; echo "${drift[*]}")"
    exit 1
  fi
  echo "nats-deploy: in sync with main@$MAIN_REV"; exit 0
fi

code_changed=0
while IFS= read -r f; do
  f="${f#./}"
  if [[ ! -f "$DEST/$f" ]] || ! cmp -s "$SRC/$f" "$DEST/$f"; then
    install -D -m 0644 "$SRC/$f" "$DEST/$f"
    code_changed=1
    echo "nats-deploy: installed $f"
  fi
done < <(cd "$SRC" && find . -type f \( -name '*.py' -o -name '*.json' \) -not -path '*/tests/*' -not -path '*/__pycache__/*')
if [[ "$(id -u)" == 0 ]]; then
  owner="$(stat -c %U:%G "$DEST")"; chown -R "$owner" "$DEST"
fi

unit_changed=0
# AC4: the unit must not hard-pin a per-day cap; the code default (0=unlimited) governs.
if [[ -f "$UNIT_FILE" ]] && grep -Eq '^Environment=.*DISPATCH_MAX_PER_DAY=' "$UNIT_FILE"; then
  sed -i -E '/^Environment=.*DISPATCH_MAX_PER_DAY=/d' "$UNIT_FILE"
  unit_changed=1
  echo "nats-deploy: removed DISPATCH_MAX_PER_DAY pin from $UNIT_FILE"
fi
((unit_changed)) && sysctl daemon-reload
if ((code_changed || unit_changed)); then
  sysctl restart "$SERVICE"
  echo "nats-deploy: restarted $SERVICE"
fi

for r in "${tracked_rel[@]}"; do
  if [[ "$(sha "$SRC/$r")" != "$(sha "$DEST/$r")" ]]; then
    emit nats_deploy_drift main="$MAIN_REV" files="$r"
    echo "nats-deploy: receipt FAILED for $r" >&2; exit 1
  fi
  echo "receipt: $r installed==main@$MAIN_REV sha=$(sha "$DEST/$r")"
done
((code_changed || unit_changed)) && emit nats_deployed main="$MAIN_REV"
exit 0
