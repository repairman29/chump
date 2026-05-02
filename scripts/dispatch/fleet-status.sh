#!/usr/bin/env bash
# fleet-status.sh — INFRA-204
#
# Operator-facing fleet control pane: a tmux window with live views of
#   (1) ambient.jsonl tail (peripheral vision across all sessions)
#   (2) PR queue depth + open PRs (merge-queue health)
#   (3) per-agent state (lease files + worktrees + branch heads)
#
# Defaults to a 3-pane tmux layout. Falls back to a single-shot snapshot
# (no tmux required) when run with --once or when tmux is unavailable —
# this lets unattended fleet loops, CI, and headless monitors share the
# same code path.
#
# Usage:
#   scripts/dispatch/fleet-status.sh           # tmux dashboard (interactive)
#   scripts/dispatch/fleet-status.sh --once    # single snapshot to stdout
#   scripts/dispatch/fleet-status.sh --pane ambient|queue|agents
#                                              # render just one pane (used by tmux)
#
# Env:
#   CHUMP_LOCK_DIR    override .chump-locks location
#   CHUMP_AMBIENT_LOG override ambient.jsonl path
#   FLEET_REFRESH     refresh interval seconds for queue/agents panes (default 5)
#   FLEET_TMUX_SESSION  tmux session name (default "chump-fleet")

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# Resolve the canonical lock dir + ambient stream.
#
# Linked worktrees have their own .chump-locks/ for *their* lease, but the
# durable ambient.jsonl lives in the main checkout's .chump-locks/. So:
#   - LOCK_DIR is for lease enumeration (defaults to worktree-local).
#   - AMBIENT prefers the main-checkout ambient if no env override, falling
#     back to the worktree-local one.
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
  AMBIENT="$CHUMP_AMBIENT_LOG"
else
  AMBIENT="$LOCK_DIR/ambient.jsonl"
  if [[ ! -f "$AMBIENT" ]]; then
    COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [[ -n "$COMMON_DIR" ]]; then
      MAIN_ROOT="$(cd "$COMMON_DIR/.." && pwd 2>/dev/null || echo "")"
      if [[ -n "$MAIN_ROOT" && -f "$MAIN_ROOT/.chump-locks/ambient.jsonl" ]]; then
        AMBIENT="$MAIN_ROOT/.chump-locks/ambient.jsonl"
      fi
    fi
  fi
fi
REFRESH="${FLEET_REFRESH:-5}"
SESSION="${FLEET_TMUX_SESSION:-chump-fleet}"

# ---------- pane renderers ----------

render_ambient() {
  echo "========== ambient.jsonl tail ($(date -u +%H:%M:%SZ)) =========="
  if [[ -f "$AMBIENT" ]]; then
    local total edits commits alerts
    total=$(wc -l <"$AMBIENT" | tr -d ' ')
    edits=$(grep -c '"event":"file_edit"' "$AMBIENT" 2>/dev/null || echo 0)
    commits=$(grep -c '"event":"commit"' "$AMBIENT" 2>/dev/null || echo 0)
    alerts=$(grep -c 'ALERT' "$AMBIENT" 2>/dev/null || echo 0)
    echo "stream: ${total} events  edits=${edits} commits=${commits} alerts=${alerts}"
    echo "----"
    tail -n 30 "$AMBIENT"
  else
    echo "(no ambient stream at $AMBIENT)"
  fi
}

render_queue() {
  echo "========== PR queue depth ($(date -u +%H:%M:%SZ)) =========="
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "(gh not installed or not authenticated)"
    return
  fi

  local open_count auto_count queued_count
  open_count=$(gh pr list --state open --json number --jq 'length' 2>/dev/null || echo "?")
  echo "open PRs: ${open_count}"

  # auto-merge armed
  auto_count=$(gh pr list --state open --json number,autoMergeRequest \
                 --jq '[.[] | select(.autoMergeRequest != null)] | length' 2>/dev/null || echo "?")
  echo "auto-merge armed: ${auto_count}"

  # github merge-queue (best-effort; the REST endpoint isn't part of the public
  # API on every plan, so swallow stderr+errors and report n/a instead).
  queued_count=$(gh api "repos/{owner}/{repo}/queues/main/entries" --jq 'length' 2>/dev/null)
  if [[ -z "$queued_count" || "$queued_count" == *"Not Found"* || "$queued_count" == *"message"* ]]; then
    queued_count="n/a"
  fi
  echo "merge-queue depth: ${queued_count}"
  echo "----"

  # Per-PR brief: number, mergeStateStatus, lifecycle
  gh pr list --state open \
    --json number,title,headRefName,mergeStateStatus,autoMergeRequest,isDraft \
    --jq '.[] | "  #\(.number) [\(.mergeStateStatus // "?")\(if .autoMergeRequest then " auto" else "" end)\(if .isDraft then " draft" else "" end)] \(.headRefName) — \(.title)"' \
    2>/dev/null | head -n 25 || echo "(failed to enumerate open PRs)"
}

render_agents() {
  echo "========== per-agent state ($(date -u +%H:%M:%SZ)) =========="
  mkdir -p "$LOCK_DIR" 2>/dev/null || true

  shopt -s nullglob
  local leases=("$LOCK_DIR"/*.json)
  shopt -u nullglob

  echo "live leases: ${#leases[@]}"
  if [[ ${#leases[@]} -gt 0 ]]; then
    local PY="${PYTHON:-python3}"
    if command -v "$PY" >/dev/null 2>&1; then
      "$PY" -c '
import json, os, sys, time
now = time.time()
rows = []
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception as exc:
        rows.append((os.path.basename(path), "?", "?", "?", "?", "unparseable: %s" % exc))
        continue
    sess = d.get("session_id") or d.get("session") or "?"
    gap = d.get("gap_id") or (d.get("pending_new_gap") or {}).get("id") or "(none)"
    wt = d.get("worktree") or d.get("cwd") or "?"
    if isinstance(wt, str) and len(wt) > 50:
        wt = "..." + wt[-47:]
    expires = d.get("expires_at") or d.get("expires") or ""
    age = ""
    try:
        st = os.stat(path)
        age = "%dm" % int((now - st.st_mtime) / 60)
    except OSError:
        pass
    rows.append((os.path.basename(path), sess[:18], gap, age, wt, expires))
print("  %-28s %-19s %-14s %-5s %-50s %s" % ("lease", "session", "gap", "age", "worktree", "expires"))
for r in rows:
    print("  %-28s %-19s %-14s %-5s %-50s %s" % r)
' "${leases[@]}" 2>/dev/null || {
        for f in "${leases[@]}"; do echo "  $f"; done
      }
    else
      for f in "${leases[@]}"; do echo "  $f"; done
    fi
  fi

  echo "----"
  echo "linked worktrees:"
  git worktree list 2>/dev/null | sed 's/^/  /' | head -n 20 || echo "  (git worktree list failed)"
}

render_all() {
  render_agents
  echo
  render_queue
  echo
  render_ambient
}

# ---------- entrypoint ----------

mode="tmux"
pane=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)        mode="once"; shift ;;
    --pane)        pane="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '1,30p' "$0"; exit 0 ;;
    *)             echo "[fleet-status] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$pane" ]]; then
  case "$pane" in
    ambient) render_ambient ;;
    queue)   render_queue ;;
    agents)  render_agents ;;
    *)       echo "[fleet-status] unknown --pane: $pane (want ambient|queue|agents)" >&2; exit 2 ;;
  esac
  exit 0
fi

if [[ "$mode" == "once" ]]; then
  render_all
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "[fleet-status] tmux not installed — falling back to --once snapshot" >&2
  render_all
  exit 0
fi

# Build tmux dashboard. Re-attach if the session already exists.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[fleet-status] attaching to existing tmux session '$SESSION'"
  exec tmux attach -t "$SESSION"
fi

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Pane 0 (left, large): ambient tail via tail -F so the stream is live without
# repolling. Pane 1 (top right): PR queue. Pane 2 (bottom right): per-agent.
if [[ -f "$AMBIENT" ]]; then
  ambient_cmd="tail -F '$AMBIENT'"
else
  ambient_cmd="while true; do '$SELF' --pane ambient; sleep $REFRESH; clear; done"
fi

queue_cmd="while true; do clear; '$SELF' --pane queue; sleep $REFRESH; done"
agents_cmd="while true; do clear; '$SELF' --pane agents; sleep $REFRESH; done"

tmux new-session -d -s "$SESSION" -n fleet -x 220 -y 60 "$ambient_cmd"
tmux split-window -h -t "$SESSION:fleet" -p 50 "$queue_cmd"
tmux split-window -v -t "$SESSION:fleet.1" -p 50 "$agents_cmd"
tmux select-pane -t "$SESSION:fleet.0"
tmux set-option -t "$SESSION" status-right "chump fleet | refresh ${REFRESH}s"

echo "[fleet-status] tmux session '$SESSION' created (ambient | queue | agents)"
echo "[fleet-status] attaching... (detach with C-b d)"
exec tmux attach -t "$SESSION"
