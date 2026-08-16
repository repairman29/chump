#!/data/data/com.termux/files/usr/bin/bash
# pixel-worker.sh — Pixel 8 Pro express-lane fleet worker (RESILIENT-336 Stage 1).
# Picks a small (xs/s), non-rust, non-external gap and executes it via the
# cascade (deepseek-v4-pro primary). Failed gaps get a cooldown so the loop
# advances instead of re-hammering one hard gap.
set -uo pipefail

export CHUMP_HOME="${CHUMP_HOME:-$HOME/chump}"
export CHUMP_REPO="${CHUMP_REPO:-$HOME/chump-repo}"
cd "$CHUMP_REPO" || { echo "[pixel-worker] no repo at $CHUMP_REPO" >&2; exit 1; }

if [ -f "$CHUMP_HOME/.env" ]; then
  set -a; . "$CHUMP_HOME/.env"; set +a
fi

export WORKER_SKILLS="${WORKER_SKILLS:-docs,shell,scripts,md}"
export WORKER_MACHINE="${WORKER_MACHINE:-pixel-8-pro}"
export CHUMP_WORK_BACKEND="${CHUMP_WORK_BACKEND:-chump-local}"
export FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P1,P2}"

BIN="${CHUMP_BIN:-$CHUMP_HOME/chump}"
IDLE_S="${PIXEL_WORKER_IDLE_S:-60}"
COOLDOWN_S="${PIXEL_WORKER_COOLDOWN_S:-3600}"
REFRESH_S="${PIXEL_WORKER_REFRESH_S:-1800}"
FAILED_FILE="$HOME/pixel-worker-failed.tsv"   # gap_id<TAB>epoch_s
LAST_REFRESH=0

[ -x "$BIN" ] || { echo "[pixel-worker] chump binary not found at $BIN" >&2; exit 1; }

echo "[pixel-worker] up: skills=$WORKER_SKILLS machine=$WORKER_MACHINE backend=$CHUMP_WORK_BACKEND bin=$BIN cooldown=${COOLDOWN_S}s"

while true; do
  echo "[pixel-worker] $(date -u +%FT%TZ) tick"
  NOW=$(date +%s)

  # Periodic state refresh (INFRA-3628): the node's local registry drifts from
  # origin/main. Reconcile every REFRESH_S by pulling fresh docs/gaps and syncing
  # state.db from the per-file mirror (fresher than the committed state.sql).
  if [ $(( NOW - LAST_REFRESH )) -ge "$REFRESH_S" ]; then
    echo "[pixel-worker] refreshing state from origin/main..."
    git -C "$CHUMP_REPO" fetch origin main --depth 1 >/dev/null 2>&1 \
      && git -C "$CHUMP_REPO" reset --hard origin/main >/dev/null 2>&1
    "$BIN" gap sync --pull >/dev/null 2>&1 || true
    LAST_REFRESH="$NOW"
    echo "[pixel-worker] state refreshed"
  fi

  # Prune expired cooldown entries (gap_id<TAB>epoch, keep only still-cooling).
  if [ -f "$FAILED_FILE" ]; then
    awk -v now="$NOW" -v cd="$COOLDOWN_S" 'now - $2 < cd {print}' "$FAILED_FILE" > "$FAILED_FILE.tmp" 2>/dev/null
    mv "$FAILED_FILE.tmp" "$FAILED_FILE" 2>/dev/null || rm -f "$FAILED_FILE"
  fi

  GAP="$("$BIN" gap list --status open --json 2>/dev/null | COOLDOWN_FILE="$FAILED_FILE" python3 -c '
import sys, json, os
skills = {s.strip() for s in os.environ.get("WORKER_SKILLS", "").split(",") if s.strip()}
prio = set(os.environ.get("FLEET_PRIORITY_FILTER", "P1,P2").split(","))
cool = set()
cf = os.environ.get("COOLDOWN_FILE", "")
if cf and os.path.exists(cf):
    for line in open(cf):
        p = line.strip().split("\t")
        if p:
            cool.add(p[0])
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for g in rows:
    gid = g.get("id", "")
    if gid in cool:
        continue
    req = {s.strip() for s in (g.get("skills_required") or "").split(",") if s.strip()}
    if any(r.startswith("external_repo:") for r in req):
        continue
    if "workspace_scope" in req:
        continue
    if "rust" in req:
        continue
    if req and not (req & skills):
        continue
    if g.get("effort") not in ("xs", "s"):
        continue
    if prio and g.get("priority") not in prio:
        continue
    print(gid)
    break
')"

  if [ -z "$GAP" ]; then
    NCOOL=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    echo "[pixel-worker] no pickable gap (${NCOOL} in cooldown); sleep ${IDLE_S}s"
    sleep "$IDLE_S"
    continue
  fi

  echo "[pixel-worker] executing gap=$GAP"
  "$BIN" --execute-gap "$GAP" 2>&1 | tail -40
  rc=${PIPESTATUS[0]}

  if [ "$rc" -eq 0 ]; then
    echo "[pixel-worker] gap=$GAP shipped (rc=0)"
    if [ -f "$FAILED_FILE" ]; then
      grep -v "^${GAP}	" "$FAILED_FILE" > "$FAILED_FILE.tmp" 2>/dev/null && mv "$FAILED_FILE.tmp" "$FAILED_FILE" 2>/dev/null || true
    fi
  else
    echo "[pixel-worker] gap=$GAP failed rc=$rc; cooldown ${COOLDOWN_S}s"
    printf "%s\t%s\n" "$GAP" "$(date +%s)" >> "$FAILED_FILE"
  fi
  sleep "$IDLE_S"
done
