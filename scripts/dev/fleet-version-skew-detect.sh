#!/usr/bin/env bash
# fleet-version-skew-detect.sh — INFRA-609
#
# Detects when the running fleet's worker.sh is behind origin/main.
# If main contains changes to scripts/dispatch/worker.sh that affect
# telemetry (waste-tally, ambient emit, gap-ship events), the running
# fleet will produce unreliable numbers until relaunched.
#
# Usage:
#   scripts/dev/fleet-version-skew-detect.sh [--quiet] [--no-emit]
#
#   --quiet    suppress human-readable output; still emits to ambient.jsonl
#   --no-emit  skip ambient.jsonl write (dry-run / testing)
#
# Exit codes:
#   0  no skew detected (or git fetch/diff unavailable)
#   1  skew detected on scripts/dispatch/worker.sh

set -euo pipefail

QUIET=0
NO_EMIT=0
for _arg in "$@"; do
  case "$_arg" in
    --quiet)   QUIET=1 ;;
    --no-emit) NO_EMIT=1 ;;
  esac
done

log() { [ "$QUIET" = "1" ] || printf 'fleet-version-skew: %s\n' "$*" >&2; }
err() { printf 'fleet-version-skew: ERROR: %s\n' "$*" >&2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# Resolve canonical ambient.jsonl path (main checkout, not worktree).
LOCK_DIR="$REPO_ROOT/.chump-locks"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" != ".git" ]]; then
  _MAIN_ROOT="$(cd "$_GIT_COMMON/.." && pwd 2>/dev/null || echo "")"
  if [[ -n "$_MAIN_ROOT" ]]; then
    LOCK_DIR="$_MAIN_ROOT/.chump-locks"
  fi
fi
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

WORKER_PATH="scripts/dispatch/worker.sh"

# ── 1. Ensure we have a remote ref to compare against ─────────────────────────
if ! git fetch origin main --quiet 2>/dev/null; then
  log "could not fetch origin/main — skipping skew check (offline?)"
  exit 0
fi

# ── 2. RESILIENT-155: compare the WORKING-TREE worker.sh (what the fleet
# actually executes) against origin/main — NOT HEAD. The main checkout's HEAD is
# PERMANENTLY behind origin/main: the dirty tree (docs/gaps/*.yaml + state.db
# mutate constantly) blocks `git pull`/ff-merge, so HEAD never advances.
# RESILIENT-152 self-sync keeps the WORKING TREE current (via
# `git checkout origin/main -- scripts/`) without advancing HEAD. A HEAD-based
# check therefore reports skew FOREVER even when the working tree is current →
# the autorestart daemon loops endlessly. Measure what the workers run.
MAIN_SHA="$(git rev-parse origin/main 2>/dev/null || echo "")"
if [[ -z "$MAIN_SHA" ]]; then
  log "could not resolve origin/main SHA — skipping"
  exit 0
fi

# GATE: does the working-tree worker.sh differ from origin/main? If self-sync
# has deployed the current version, this is clean → no skew (breaks the loop).
if git diff --quiet "origin/main" -- "$WORKER_PATH" 2>/dev/null; then
  log "working-tree worker.sh == origin/main — no skew (self-sync current)"
  exit 0
fi

# Informational only: how many origin/main commits since HEAD touched worker.sh
# (context for the report — the GATE above is the working-tree diff, not this).
LOCAL_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
COMMITS_BEHIND=$(git log --oneline "${LOCAL_SHA}..${MAIN_SHA}" -- "$WORKER_PATH" 2>/dev/null | wc -l | tr -d ' ')
if [[ -z "$COMMITS_BEHIND" || "$COMMITS_BEHIND" -eq 0 ]]; then COMMITS_BEHIND=1; fi

# ── 3. Identify affected lines (working tree vs origin/main) ───────────────────
DIFF_OUTPUT="$(git diff "origin/main" -- "$WORKER_PATH" 2>/dev/null || true)"

# Extract only added/removed lines (not hunk headers).
AFFECTED_LINES="$(printf '%s\n' "$DIFF_OUTPUT" \
  | grep -E '^[+-]' \
  | grep -v '^[+-]{3}' \
  | head -40 \
  || true)"

# Classify whether any changed lines touch telemetry paths.
TELEMETRY_TERMS='ambient[-_]emit|waste[-_]tally|gap.*ship|gap.*shipped|fleet_waste|INFRA-583|telemetry'
TELEMETRY_AFFECTED=0
if printf '%s\n' "$AFFECTED_LINES" | grep -qE "$TELEMETRY_TERMS" 2>/dev/null; then
  TELEMETRY_AFFECTED=1
fi

# ── 4. Human-readable output ──────────────────────────────────────────────────
if [[ "$QUIET" = "0" ]]; then
  printf '\n⚠️  FLEET VERSION SKEW DETECTED\n'
  printf '   File:             %s\n' "$WORKER_PATH"
  printf '   Commits behind:   %d commit(s) in origin/main not in HEAD\n' "$COMMITS_BEHIND"
  printf '   Telemetry impact: %s\n' "$([ "$TELEMETRY_AFFECTED" = "1" ] && echo "YES — waste-tally numbers are unreliable" || echo "no telemetry lines affected")"
  printf '\n   Affected lines (sample):\n'
  printf '%s\n' "$AFFECTED_LINES" | head -20 | sed 's/^/     /'
  printf '\n   ➜  Recommended action: tmux kill-session -t chump-fleet && relaunch fleet\n\n'
fi

# ── 5. Emit ambient ALERT ─────────────────────────────────────────────────────
if [[ "$NO_EMIT" = "0" ]]; then
  mkdir -p "$LOCK_DIR"
  SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Escape affected lines for JSON (strip newlines, escape quotes).
  AFFECTED_JSON="$(printf '%s' "$AFFECTED_LINES" \
    | head -10 \
    | tr '\n' '|' \
    | sed 's/"/\\"/g' \
    | sed "s/'/\\\\'/g")"

  EMIT_SCRIPT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
  if [[ -x "$EMIT_SCRIPT" ]]; then
    "$EMIT_SCRIPT" ALERT \
      "kind=fleet_version_skew" \
      "file=$WORKER_PATH" \
      "commits_behind=$COMMITS_BEHIND" \
      "telemetry_affected=$TELEMETRY_AFFECTED" \
      "action=tmux kill-session -t chump-fleet && relaunch" \
      "session=$SESSION_ID" \
      2>/dev/null || true
  else
    # Fallback: write directly without flock.
    printf '{"ts":"%s","kind":"fleet_version_skew","file":"%s","commits_behind":%d,"telemetry_affected":%s,"affected_lines":"%s","action":"tmux kill-session -t chump-fleet && relaunch","session":"%s"}\n' \
      "$TS" "$WORKER_PATH" "$COMMITS_BEHIND" \
      "$([ "$TELEMETRY_AFFECTED" = "1" ] && echo "true" || echo "false")" \
      "$AFFECTED_JSON" "$SESSION_ID" \
      >> "$AMBIENT" 2>/dev/null || true
  fi
  log "fleet_version_skew event written to $AMBIENT"
fi

exit 1
