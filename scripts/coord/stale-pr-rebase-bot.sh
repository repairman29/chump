#!/usr/bin/env bash
# scripts/coord/stale-pr-rebase-bot.sh — INFRA-2295
#
# Rebase-before-reap safety net (SCALE-C). Finds open PRs with auto-merge
# armed that have gone stale and tries to rebase them rather than letting the
# stale-pr-reaper destroy them.
#
# Doctrine: see docs/process/REAPER_DOCTRINE.md
#
# Priority order per PR:
#   1. gh pr update-branch (GitHub-side merge; no local disk touch)
#   2. Local worktree rebase + force-with-lease push (INFRA-1958 false-positive fallback)
#   3. If both fail: increment strike counter in .chump-locks/rebase-bot-strikes/<PR>.json
#   4. After 3 strikes: emit stale_pr_unrebaseable + WARN broadcast; NEVER close the PR
#
# Guards:
#   - Trunk-RED: if trunk-red-detector-state.json has last_failed_sha, skip cycle
#   - Hysteresis: skip re-attempt within CHUMP_REBASE_BOT_HYSTERESIS_MINS of last try
#
# Telemetry (emitted to .chump-locks/ambient.jsonl):
#   kind=stale_pr_auto_rebased                     — GH-side or local rebase succeeded
#   kind=stale_pr_rebase_failed                    — one attempt failed (not yet 3-strike)
#   kind=stale_pr_unrebaseable                     — 3-strike threshold reached; operator must decide
#   kind=stale_pr_rebase_bot_holding_for_trunk_red — trunk is RED; cycle skipped
#
# Usage:
#   bash scripts/coord/stale-pr-rebase-bot.sh [--dry-run]
#   CHUMP_REBASE_BOT_STALE_MINS=30 bash scripts/coord/stale-pr-rebase-bot.sh
#
# Env knobs:
#   CHUMP_REBASE_BOT_STALE_MINS       — PRs older than N minutes considered stale (default 120)
#   CHUMP_REBASE_BOT_HYSTERESIS_MINS  — skip re-attempt within N minutes of last try (default 30)
#   CHUMP_REBASE_BOT_STRIKE_LIMIT     — strikes before stale_pr_unrebaseable (default 3)
#   CHUMP_REBASE_BOT_NO_FALLBACK      — skip local-rebase fallback; trust gh API (default 0)
#   CHUMP_REBASE_BOT_AMBIENT_FILE     — override ambient.jsonl path (used in tests)
#   CHUMP_REBASE_BOT_STATE_FILE       — override trunk-red state file path (used in tests)
#   CHUMP_REBASE_BOT_STRIKES_DIR      — override strikes dir path (used in tests)
#   CHUMP_REBASE_BOT_GH_FIXTURE       — path to fixture JSON; overrides gh pr list (tests only)
#   CHUMP_REBASE_BOT_BROADCAST_SCRIPT — override broadcast.sh path (used in tests)
#   CHUMP_REBASE_BOT_NOW_OVERRIDE     — ISO-8601 timestamp to use as "now" (used in tests)

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

# Use the main worktree's .chump-locks, not a linked worktree's sibling.
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$(dirname "$_GIT_COMMON")" && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
mkdir -p "$LOCK_DIR"

# ── Configuration ─────────────────────────────────────────────────────────────
STALE_MINS="${CHUMP_REBASE_BOT_STALE_MINS:-120}"
HYSTERESIS_MINS="${CHUMP_REBASE_BOT_HYSTERESIS_MINS:-30}"
STRIKE_LIMIT="${CHUMP_REBASE_BOT_STRIKE_LIMIT:-3}"
NO_FALLBACK="${CHUMP_REBASE_BOT_NO_FALLBACK:-0}"

AMBIENT="${CHUMP_REBASE_BOT_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
TRUNK_RED_STATE="${CHUMP_REBASE_BOT_STATE_FILE:-$LOCK_DIR/trunk-red-detector-state.json}"
STRIKES_DIR="${CHUMP_REBASE_BOT_STRIKES_DIR:-$LOCK_DIR/rebase-bot-strikes}"
BROADCAST_SCRIPT="${CHUMP_REBASE_BOT_BROADCAST_SCRIPT:-$REPO_ROOT/scripts/coord/broadcast.sh}"

DRY_RUN=0
for _a in "$@"; do
    case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    esac
done

mkdir -p "$STRIKES_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() {
    if [[ -n "${CHUMP_REBASE_BOT_NOW_OVERRIDE:-}" ]]; then
        printf '%s' "$CHUMP_REBASE_BOT_NOW_OVERRIDE"
    else
        date -u +%Y-%m-%dT%H:%M:%SZ
    fi
}

emit() {
    local kind="$1" pr="${2:-}" extra="${3:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$pr" && -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr,$extra}"
    elif [[ -n "$pr" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

log() { printf '[stale-pr-rebase-bot] %s\n' "$*"; }

# iso_to_epoch ISO — convert ISO-8601 UTC string to epoch seconds.
# Uses python3 for portability across macOS + Linux.
iso_to_epoch() {
    python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('$1'.replace('Z','+00:00'))
    print(int(t.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

now_epoch() {
    if [[ -n "${CHUMP_REBASE_BOT_NOW_OVERRIDE:-}" ]]; then
        iso_to_epoch "$CHUMP_REBASE_BOT_NOW_OVERRIDE"
    else
        date -u +%s
    fi
}

# mins_since ISO — how many minutes ago was ISO timestamp.
mins_since() {
    local epoch; epoch="$(iso_to_epoch "$1")"
    local now; now="$(now_epoch)"
    echo $(( (now - epoch) / 60 ))
}

# ── Guard: trunk-RED ─────────────────────────────────────────────────────────
# If trunk-red-detector-state.json exists and has last_failed_sha set, trunk is
# RED. Don't burn rebase cycles when CI is wedged — rebased branches would just
# queue behind failing trunk commits.
_trunk_is_red() {
    [[ ! -f "$TRUNK_RED_STATE" ]] && return 1
    local sha
    sha="$(python3 -c "
import json, sys
try:
    d = json.load(open('$TRUNK_RED_STATE'))
    sha = d.get('last_failed_sha') or ''
    print(sha)
except Exception:
    print('')
" 2>/dev/null || echo "")"
    [[ -n "$sha" ]]
}

if _trunk_is_red; then
    log "Trunk is RED — skipping cycle to avoid wasted rebase attempts."
    emit "stale_pr_rebase_bot_holding_for_trunk_red"
    exit 0
fi

# ── Find stale armed PRs ──────────────────────────────────────────────────────
# A PR is a candidate when:
#   - auto-merge is armed (.autoMergeRequest != null)
#   - updatedAt is older than STALE_MINS
#
# We compute the cutoff as an ISO timestamp by subtracting STALE_MINS*60 from now.
CUTOFF_EPOCH=$(( $(now_epoch) - STALE_MINS * 60 ))
CUTOFF_ISO="$(python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp($CUTOFF_EPOCH, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || date -u -r "$CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -n "${CHUMP_REBASE_BOT_GH_FIXTURE:-}" ]]; then
    PRS_JSON="$(cat "$CHUMP_REBASE_BOT_GH_FIXTURE")"
else
    PRS_JSON="$(gh pr list \
        --state open \
        --limit 80 \
        --json number,headRefName,autoMergeRequest,updatedAt,mergeStateStatus \
        2>/dev/null || echo '[]')"
fi

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    log "No open PRs found (or gh unavailable)."
    exit 0
fi

# Filter: armed + stale.
TARGETS="$(printf '%s' "$PRS_JSON" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
cutoff = '$CUTOFF_ISO'
for r in rows:
    if not r.get('autoMergeRequest'):
        continue
    updated = r.get('updatedAt') or ''
    if updated and updated < cutoff:
        print('\t'.join([
            str(r.get('number','')),
            r.get('headRefName','') or '',
            r.get('mergeStateStatus','') or '',
            updated,
        ]))
" 2>/dev/null || true)"

if [[ -z "$TARGETS" ]]; then
    log "No armed PRs stale > ${STALE_MINS}m."
    exit 0
fi

# ── Process each candidate ────────────────────────────────────────────────────
REBASED=0
SKIPPED=0
FAILED=0
STRUCK_OUT=0

while IFS=$'\t' read -r PR BRANCH MSS UPDATED_AT; do
    [[ -z "$PR" ]] && continue

    log "Checking #$PR (branch=$BRANCH, mss=$MSS, updated=$UPDATED_AT)"

    # ── Hysteresis: was this PR attempted recently? ───────────────────────────
    STRIKE_FILE="$STRIKES_DIR/${PR}.json"
    last_attempt=""
    if [[ -f "$STRIKE_FILE" ]]; then
        last_attempt="$(python3 -c "
import json, sys
try:
    d = json.load(open('$STRIKE_FILE'))
    print(d.get('last_attempt_ts') or '')
except Exception:
    print('')
" 2>/dev/null || echo "")"
    fi

    if [[ -n "$last_attempt" ]]; then
        mins_ago="$(mins_since "$last_attempt")"
        if (( mins_ago < HYSTERESIS_MINS )); then
            log "  SKIP #$PR — attempted ${mins_ago}m ago (hysteresis=${HYSTERESIS_MINS}m)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    # ── Read current strike count ─────────────────────────────────────────────
    strikes=0
    if [[ -f "$STRIKE_FILE" ]]; then
        strikes="$(python3 -c "
import json, sys
try:
    d = json.load(open('$STRIKE_FILE'))
    print(int(d.get('strikes') or 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    fi

    # Already at or past strike limit — just remind operator, don't attempt again.
    if (( strikes >= STRIKE_LIMIT )); then
        log "  SKIP #$PR — already at ${strikes} strikes (limit=${STRIKE_LIMIT}); waiting for operator action"
        STRUCK_OUT=$((STRUCK_OUT + 1))
        continue
    fi

    log "  Attempting rebase for #$PR (strikes=${strikes}/${STRIKE_LIMIT})..."

    if (( DRY_RUN )); then
        log "  DRY-RUN: would attempt gh pr update-branch $PR"
        continue
    fi

    # ── Step 1: GH-side rebase ────────────────────────────────────────────────
    NOW_TS="$(_ts)"
    gh_ok=0
    if gh pr update-branch "$PR" >/dev/null 2>&1; then
        gh_ok=1
    fi

    if (( gh_ok )); then
        log "  OK #$PR — GH-side rebase succeeded."
        emit "stale_pr_auto_rebased" "$PR" \
            "\"branch\":\"$BRANCH\",\"method\":\"gh_update_branch\",\"prior_strikes\":$strikes"
        # Clear strike file on success — slate is clean.
        rm -f "$STRIKE_FILE"
        REBASED=$((REBASED + 1))
        continue
    fi

    # ── Step 2: Local worktree rebase fallback ────────────────────────────────
    # gh pr update-branch has a documented false-positive conflict rate (INFRA-1958).
    # Try local rebase in an ephemeral worktree before counting a strike.
    local_ok=0
    if [[ "$NO_FALLBACK" != "1" ]]; then
        log "  gh API reported conflict — trying local rebase fallback (INFRA-1958)..."
        WT="$(mktemp -d -t chump-rebase-bot-XXXXXX)"

        # Ensure branch ref is current.
        git -C "$REPO_ROOT" fetch origin "$BRANCH" --quiet 2>/dev/null || true
        git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true

        if git -C "$REPO_ROOT" worktree add "$WT" "origin/$BRANCH" >/dev/null 2>&1; then
            _srb_orig="$(cd "$WT" && git rev-parse HEAD 2>/dev/null || true)"
            if (cd "$WT" && git rebase origin/main >/dev/null 2>&1); then
                # INFRA-1526: verify no hunks dropped silently before pushing
                _srb_rebased="$(cd "$WT" && git rev-parse HEAD 2>/dev/null || true)"
                _srb_verify="$REPO_ROOT/scripts/coord/rebase-hunk-verify.sh"
                if [[ -x "$_srb_verify" && -n "$_srb_orig" && -n "$_srb_rebased" ]]; then
                    if ! (cd "$WT" && "$_srb_verify" --ambient "$AMBIENT" \
                        "$_srb_orig" "$_srb_rebased" "origin/main") 2>/dev/null; then
                        log "  WARN #$PR — hunk drop detected post-rebase, skipping push"
                        emit "stale_pr_rebase_failed" "$PR" \
                            "\"branch\":\"$BRANCH\",\"reason\":\"hunk_drop_detected\",\"prior_strikes\":$strikes"
                        local_ok=0
                        git -C "$REPO_ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
                        rm -rf "$WT" 2>/dev/null || true
                        continue
                    fi
                fi
                if (cd "$WT" && git push origin "HEAD:$BRANCH" --force-with-lease >/dev/null 2>&1); then
                    log "  OK #$PR — local-rebase fallback succeeded."
                    emit "stale_pr_auto_rebased" "$PR" \
                        "\"branch\":\"$BRANCH\",\"method\":\"local_rebase_fallback\",\"prior_strikes\":$strikes"
                    rm -f "$STRIKE_FILE"
                    local_ok=1
                    REBASED=$((REBASED + 1))
                else
                    log "  FAIL #$PR — local rebase OK but push rejected."
                fi
            else
                (cd "$WT" && git rebase --abort >/dev/null 2>&1) || true
                log "  FAIL #$PR — true conflict confirmed by local rebase."
            fi
            git -C "$REPO_ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
        else
            log "  FAIL #$PR — could not create worktree for fallback."
        fi
        rm -rf "$WT" 2>/dev/null || true
    fi

    (( local_ok )) && continue

    # ── Both methods failed: increment strike counter ─────────────────────────
    new_strikes=$(( strikes + 1 ))

    python3 - "$STRIKE_FILE" <<PYEOF
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    d = {}
d['strikes'] = $new_strikes
d['pr'] = $PR
d['branch'] = '$BRANCH'
d['last_attempt_ts'] = '$NOW_TS'
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
PYEOF

    log "  Strike ${new_strikes}/${STRIKE_LIMIT} recorded for #$PR."
    emit "stale_pr_rebase_failed" "$PR" \
        "\"branch\":\"$BRANCH\",\"strikes\":$new_strikes,\"strike_limit\":$STRIKE_LIMIT"
    FAILED=$((FAILED + 1))

    # ── 3-strike threshold: escalate, do NOT close ────────────────────────────
    if (( new_strikes >= STRIKE_LIMIT )); then
        log "  WARN #$PR — ${new_strikes} strikes reached. Operator must decide. PR left open."
        emit "stale_pr_unrebaseable" "$PR" \
            "\"branch\":\"$BRANCH\",\"strikes\":$new_strikes,\"note\":\"operator_action_required\""

        # Broadcast WARN so it surfaces in next session-start digest.
        if [[ -x "$BROADCAST_SCRIPT" ]]; then
            "$BROADCAST_SCRIPT" --urgency WARN WARN \
                "PR #${PR} (branch=${BRANCH}) is unrebaseable after ${new_strikes} strikes. Operator must resolve or close manually. See .chump-locks/rebase-bot-strikes/${PR}.json" \
                2>/dev/null || true
        fi
        STRUCK_OUT=$((STRUCK_OUT + 1))
    fi

done <<< "$TARGETS"

log "done — rebased=${REBASED} skipped=${SKIPPED} failed=${FAILED} struck_out=${STRUCK_OUT}"
exit 0
