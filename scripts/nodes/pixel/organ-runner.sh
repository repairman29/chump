#!/data/data/com.termux/files/usr/bin/bash
# pixel-organ-runner.sh — Termux-native port of Helsinki's systemd organ set
# (RESILIENT-349 / SOVEREIGN: "get Helsinki onto the Pixel"). Runs the patient's
# COORDINATION organs on the Pixel, on their real cadences, without systemd.
#
# Design:
#   - Reads ~/organs/manifest: "name|cadence_s|guard|command" (cwd = REPO).
#   - Runs each organ when due (tracks last-run in ~/organs/last/<name>).
#   - guard=safe  → always runs (health-check/heartbeat; self-limits via autonomy dial).
#   - guard=mutating → runs ONLY if ~/organs/ACTIVE exists (standby-patient gate:
#       prevents double-action against Helsinki until the operator promotes the Pixel).
#   - Single-writer organs (backlog-sync) are NOT in the manifest — two writers
#     recreate the CREDIBLE-292 split-brain.
#   - Started by Termux:Boot, holds wake-lock. Its own liveness = the supervisor.
set -uo pipefail
REPO="${CHUMP_REPO:-$HOME/chump-repo}"
ENVF="${CHUMP_ENV:-$HOME/chump/.env}"
BIN="${CHUMP_BIN:-$HOME/chump/chump}"
ORG="$HOME/organs"
LAST="$ORG/last"
LOG="$ORG/organs.log"
mkdir -p "$LAST"
export PATH="$HOME/chump:$PATH"
termux-wake-lock 2>/dev/null || true

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

run_organ() {
  local name="$1" guard="$2" cmd="$3"
  if [ "$guard" = "mutating" ] && [ ! -f "$ORG/ACTIVE" ]; then
    return  # standby: declared but not firing until the Pixel is promoted
  fi
  log "[$name] start (guard=$guard)"
  ( cd "$REPO" 2>/dev/null || exit 1
    set -a; . "$ENVF" 2>/dev/null; set +a
    export CHUMP_REPO_ROOT="$REPO" CHUMP_REPO="$REPO"
    timeout 300 bash -lc "$cmd" ) >> "$LOG" 2>&1
  log "[$name] done rc=$?"
  date +%s > "$LAST/$name"
}

log "=== pixel-organ-runner up (repo=$REPO active=$([ -f "$ORG/ACTIVE" ] && echo yes || echo standby)) ==="
while true; do
  now=$(date +%s)
  while IFS='|' read -r name cadence guard cmd; do
    case "$name" in ''|\#*) continue;; esac
    lastf="$LAST/$name"; last=0; [ -f "$lastf" ] && last=$(cat "$lastf" 2>/dev/null || echo 0)
    if [ $(( now - last )) -ge "$cadence" ]; then
      run_organ "$name" "$guard" "$cmd"
    fi
  done < "$ORG/manifest"
  sleep 20
done
