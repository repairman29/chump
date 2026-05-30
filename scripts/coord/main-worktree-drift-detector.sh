#!/usr/bin/env bash
# scripts/coord/main-worktree-drift-detector.sh — META-225
#
# Main-worktree drift detector: checks for untracked yaml files piling up
# under docs/gaps/ and commits-behind-origin/main. When thresholds are breached,
# emits an ambient alert and reserves a cleanup gap (debounced 6h).
#
# This daemon prevents the silent accumulation of drift that blocks the shepherd
# from cleanly pulling main — e.g. "150 untracked yaml + stale state.db blocked
# the shepherd from running the installer" (META-225 origin story).
#
# Emission kinds:
# scanner-anchor: "kind":"main_worktree_drift_detected"
#
# Usage:
#   bash scripts/coord/main-worktree-drift-detector.sh [--dry-run]
#
# Env knobs:
#   CHUMP_DRIFT_UNTRACKED_THRESH        — untracked yaml threshold (default 50)
#   CHUMP_DRIFT_BEHIND_THRESH           — commits-behind threshold (default 20)
#   CHUMP_DRIFT_AMBIENT_FILE            — override ambient.jsonl path (tests)
#   CHUMP_DRIFT_STATE_FILE              — override debounce state file (tests)
#   CHUMP_DRIFT_CHUMP_CMD               — override chump binary (tests)
#   CHUMP_DRIFT_SKIP_GAP_RESERVE        — set 1 to skip gap reserve (tests)
#   CHUMP_DRIFT_DRY_RUN                 — alias for CHUMP_DRIFT_SKIP_GAP_RESERVE (tests)
#   CHUMP_DRIFT_MAIN_WORKTREE           — override main worktree path (tests only)

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$(dirname "$_GIT_COMMON")" && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
CHUMP_DIR="$MAIN_REPO/.chump"
mkdir -p "$LOCK_DIR" "$CHUMP_DIR"

# ── Configuration ─────────────────────────────────────────────────────────────
UNTRACKED_THRESH="${CHUMP_DRIFT_UNTRACKED_THRESH:-50}"
BEHIND_THRESH="${CHUMP_DRIFT_BEHIND_THRESH:-20}"
AMBIENT="${CHUMP_DRIFT_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="${CHUMP_DRIFT_STATE_FILE:-$CHUMP_DIR/main-worktree-drift-last.json}"
CHUMP="${CHUMP_DRIFT_CHUMP_CMD:-chump}"
SKIP_RESERVE="${CHUMP_DRIFT_SKIP_GAP_RESERVE:-${CHUMP_DRIFT_DRY_RUN:-0}}"
DEBOUNCE_HOURS=6

for _a in "$@"; do
    case "$_a" in
    --dry-run) SKIP_RESERVE=1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[main-worktree-drift-detector] %s\n' "$*"; }

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

# hours_since ISO_TIMESTAMP — how many hours ago was ISO timestamp.
hours_since() {
    local epoch
    epoch="$(python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('$1'.replace('Z','+00:00'))
    print(int(t.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    local now
    now="$(date -u +%s)"
    echo $(( (now - epoch) / 3600 ))
}

# debounce_ok — return 0 (ok to alert) if last alert was > DEBOUNCE_HOURS ago.
debounce_ok() {
    [[ ! -f "$STATE_FILE" ]] && return 0
    local last_ts
    last_ts="$(python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('last_alert_ts') or '')
except Exception:
    print('')
" 2>/dev/null || true)"
    [[ -z "$last_ts" ]] && return 0
    local hours_ago
    hours_ago="$(hours_since "$last_ts")"
    (( hours_ago >= DEBOUNCE_HOURS ))
}

# write_debounce_state TS UNTRACKED BEHIND
write_debounce_state() {
    python3 - "$STATE_FILE" "$1" "$2" "$3" <<'PYEOF'
import json, sys
path, ts, untracked, behind = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
open(path, 'w').write(json.dumps({
    'last_alert_ts': ts,
    'untracked_count': untracked,
    'behind_count': behind,
}, indent=2) + '\n')
PYEOF
}

# suggested_action UNTRACKED BEHIND
suggested_action() {
    local untracked=$1 behind=$2
    if (( untracked > 100 )); then
        echo "commit-untracked-then-pull"
    elif (( behind > 50 )); then
        echo "force-reset-after-backup"
    else
        echo "git stash + pull"
    fi
}

# ── Step 1: Resolve and cd to main worktree ──────────────────────────────────
# CHUMP_DRIFT_MAIN_WORKTREE allows tests to inject a fake repo path.
if [[ -n "${CHUMP_DRIFT_MAIN_WORKTREE:-}" ]]; then
    MAIN_WORKTREE="$CHUMP_DRIFT_MAIN_WORKTREE"
else
    MAIN_WT_SCRIPT="$REPO_ROOT/scripts/lib/resolve-main-worktree.sh"
    if [[ -f "$MAIN_WT_SCRIPT" ]]; then
        # shellcheck source=/dev/null
        source "$MAIN_WT_SCRIPT"
        MAIN_WORKTREE="$(resolve_main_worktree "$0" 2>/dev/null || echo "$MAIN_REPO")"
    else
        MAIN_WORKTREE="$MAIN_REPO"
    fi
fi

log "Main worktree: $MAIN_WORKTREE"

# ── Step 2: Fetch origin/main ─────────────────────────────────────────────────
git -C "$MAIN_WORKTREE" fetch origin main --quiet 2>/dev/null || true

# ── Step 3: Count untracked yaml under docs/gaps/ ────────────────────────────
UNTRACKED_COUNT=0
if [[ -d "$MAIN_WORKTREE/docs/gaps" ]]; then
    UNTRACKED_COUNT="$(git -C "$MAIN_WORKTREE" ls-files \
        --others --exclude-standard docs/gaps/ 2>/dev/null \
        | grep -c '\.yaml$' || echo 0)"
fi

# ── Step 4: Count commits behind origin/main ─────────────────────────────────
BEHIND_COUNT=0
BEHIND_COUNT="$(git -C "$MAIN_WORKTREE" rev-list \
    --count HEAD..origin/main 2>/dev/null || echo 0)"

log "Untracked yaml: $UNTRACKED_COUNT (thresh=$UNTRACKED_THRESH)"
log "Commits behind: $BEHIND_COUNT (thresh=$BEHIND_THRESH)"

# ── Step 5: Check thresholds ──────────────────────────────────────────────────
THRESHOLD_BREACHED=0
if (( UNTRACKED_COUNT > UNTRACKED_THRESH )); then
    log "ALERT: untracked yaml count ($UNTRACKED_COUNT) exceeds threshold ($UNTRACKED_THRESH)"
    THRESHOLD_BREACHED=1
fi
if (( BEHIND_COUNT > BEHIND_THRESH )); then
    log "ALERT: commits-behind ($BEHIND_COUNT) exceeds threshold ($BEHIND_THRESH)"
    THRESHOLD_BREACHED=1
fi

if (( ! THRESHOLD_BREACHED )); then
    log "No drift detected — all counts within thresholds."
    exit 0
fi

# ── Step 6: Debounce ──────────────────────────────────────────────────────────
if ! debounce_ok; then
    log "SKIP: alert debounced — last alert was within ${DEBOUNCE_HOURS}h"
    exit 0
fi

# ── Step 7: Emit alert ────────────────────────────────────────────────────────
TS="$(_ts)"
ACTION="$(suggested_action "$UNTRACKED_COUNT" "$BEHIND_COUNT")"

log "Emitting main_worktree_drift_detected (untracked=$UNTRACKED_COUNT behind=$BEHIND_COUNT action=$ACTION)"
emit "main_worktree_drift_detected" \
    "\"untracked_yaml\":$UNTRACKED_COUNT,\"commits_behind\":$BEHIND_COUNT,\"suggested_action\":\"$ACTION\""

# ── Step 8: Reserve a cleanup gap ────────────────────────────────────────────
if (( ! SKIP_RESERVE )); then
    GAP_TITLE="main worktree cleanup — ${UNTRACKED_COUNT} untracked yaml + ${BEHIND_COUNT} commits behind"
    AC="Run: cd ${MAIN_WORKTREE} && git stash -u && git pull --rebase && git stash drop. Or if too many untracked files: git add docs/gaps/*.yaml && git commit -m 'chore: import accumulated gap yamls'. Verify: git status shows clean working tree and HEAD matches origin/main."
    log "Reserving cleanup gap: $GAP_TITLE"
    CHUMP_IGNORE_WASTE_PAUSE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
        "$CHUMP" gap reserve \
        --domain META \
        --priority P1 \
        --effort s \
        --title "$GAP_TITLE" \
        --acceptance-criteria "$AC" \
        2>/dev/null || log "WARN: could not reserve cleanup gap (may already exist)"
fi

# ── Step 9: Update debounce state ─────────────────────────────────────────────
write_debounce_state "$TS" "$UNTRACKED_COUNT" "$BEHIND_COUNT"

log "done — drift alert emitted; debounce state written"
exit 0
