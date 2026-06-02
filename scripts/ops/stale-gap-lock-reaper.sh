#!/usr/bin/env bash
# stale-gap-lock-reaper.sh — INFRA-676 INFRA-2447
#
# Sweeps .chump-locks/.gap-*.lock files whose owning session lease is gone.
# Companion to the in-process self-clean in try_claim_gap(): this catches
# orphaned locks from workers that were SIGKILLed or OOM-killed before they
# could clean up, and where no subsequent same-session claim has run.
#
# Logic per lock file:
#   1. Read first whitespace token → session_id
#   2. If .chump-locks/<session_id>.json exists → lease still active, SKIP
#   3. Else → no live lease for this session; delete the lock
#
# Usage:
#   ./scripts/ops/stale-gap-lock-reaper.sh              # dry-run (default)
#   ./scripts/ops/stale-gap-lock-reaper.sh --dry-run    # explicit dry-run
#   ./scripts/ops/stale-gap-lock-reaper.sh --execute    # actually delete
#
# LaunchAgent: dev.chump.stale-gap-lock-reaper (every 5 min)
#   Install: scripts/setup/install-stale-gap-lock-reaper-launchd.sh

set -euo pipefail

DRY_RUN=true
for arg in "$@"; do
    case "$arg" in
        --execute) DRY_RUN=false ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"

# INFRA-1224: canonical lease parser.
# shellcheck source=../lib/lease.sh
source "$REPO_ROOT/scripts/lib/lease.sh"

if [[ ! -d "$LOCK_DIR" ]]; then
    echo "lock dir not found: $LOCK_DIR — nothing to reap"
    exit 0
fi

REAPED=0
SKIPPED=0
ERRORS=0

for lock_file in "$LOCK_DIR"/.gap-*.lock; do
    [[ -e "$lock_file" ]] || continue

    # Extract session_id (first whitespace token in the file).
    session_id="$(awk 'NR==1{print $1; exit}' "$lock_file" 2>/dev/null || echo "")"
    if [[ -z "$session_id" ]]; then
        echo "  SKIP (unreadable): $lock_file"
        ERRORS=$((ERRORS+1))
        continue
    fi

    lease_file="$LOCK_DIR/${session_id}.json"
    if [[ -f "$lease_file" ]]; then
        # 2026-05-08 INFRA-732 extension: lease file present is NOT enough —
        # session_id encodes a PID (fleet-<...>-<PID>-<EPOCH>). If PID is
        # dead, the lease is a zombie and the lock should be reaped. Without
        # this check, the reaper missed the most common stall pattern (72
        # zombies observed mid-session, all had lease files but dead PIDs).
        pid=$(printf '%s' "$session_id" | grep -oE '[0-9]+-[0-9]+$' | cut -d- -f1)
        if [[ -n "$pid" ]] && ! ps -p "$pid" >/dev/null 2>&1; then
            # PID is dead — zombie. Reap both lock + lease.
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "  WOULD REAP (pid=$pid dead): $lock_file"
            else
                rm -f "$lock_file" "$lease_file"
                echo "  REAPED (pid=$pid dead): $lock_file + lease"
                printf '{"ts":"%s","kind":"stale_gap_lock_reaped","lock":"%s","session":"%s","reason":"pid_dead","pid":%d}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    "$(basename "$lock_file")" \
                    "$session_id" "$pid" \
                    >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
            fi
            REAPED=$((REAPED+1))
            continue
        fi
        echo "  SKIP (live lease + live pid): $lock_file  [session=$session_id]"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  WOULD REAP: $lock_file  [session=$session_id, no lease found]"
    else
        rm -f "$lock_file"
        echo "  REAPED: $lock_file  [session=$session_id]"
        printf '{"ts":"%s","kind":"stale_gap_lock_reaped","lock":"%s","session":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$(basename "$lock_file")" \
            "$session_id" \
            >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    fi
    REAPED=$((REAPED+1))
done


# ── INFRA-1017: sweep stale state.db leases rows ─────────────────────────────
# Vacuum rows whose expires_at is in the past (bot-merge killed before cleanup),
# or whose worktree path no longer exists (orphaned from a crashed session).
STATE_DB="${CHUMP_STATE_DB:-${REPO_ROOT}/.chump/state.db}"
DB_REAPED=0
if [[ -f "$STATE_DB" ]] && command -v sqlite3 &>/dev/null; then
    NOW_EPOCH="$(date +%s)"
    while IFS='|' read -r sid gid worktree expires_at; do
        [[ -z "$sid" ]] && continue
        reason=""
        if [[ "$expires_at" -lt "$NOW_EPOCH" ]]; then
            reason="expired"
        elif [[ -n "$worktree" && ! -d "$worktree" ]]; then
            reason="worktree_gone"
        fi
        [[ -z "$reason" ]] && continue

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  WOULD REAP state.db lease ($reason): session=$sid gap=$gid"
        else
            sqlite3 "$STATE_DB" \
                "DELETE FROM leases WHERE session_id='${sid}'" 2>/dev/null || true
            echo "  REAPED state.db lease ($reason): session=$sid gap=$gid"
            printf '{"ts":"%s","kind":"stale_gap_lock_reaped","session":"%s","gap":"%s","reason":"%s","source":"state.db"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "$gid" "$reason" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        fi
        DB_REAPED=$((DB_REAPED+1))
    done < <(sqlite3 "$STATE_DB" \
        "SELECT session_id,gap_id,worktree,expires_at FROM leases" 2>/dev/null || true)
fi

# ── INFRA-1164: sweep expired claim-*.json lease files ───────────────────────
# claim-*.json files are written by gap-claim.sh when a session claims a gap.
# They include an expires_at field. Sessions that crash or are killed without
# releasing leave orphaned claim files. This sweep reaps any claim file whose
# expires_at is in the past.
CLAIM_REAPED=0
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH_CLAIM="$(date -u +%s)"

for claim_file in "$LOCK_DIR"/claim-*.json; do
    [[ -e "$claim_file" ]] || continue
    # INFRA-1224: 4 python3 heredocs collapsed to lease_field shortcuts.
    expires_at="$(lease_field "$claim_file" expires_at)"
    [[ -z "$expires_at" ]] && continue

    # Convert ISO timestamp to epoch (still needs python — shell can't do
    # portable ISO date arithmetic).
    expires_epoch="$(python3 -c "
import datetime
try:
    dt = datetime.datetime.fromisoformat('$expires_at'.replace('Z', '+00:00'))
    print(int(dt.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo "0")"

    session_id="$(lease_session_id "$claim_file")"
    gap_id="$(lease_gap_id "$claim_file")"

    # INFRA-1221: open-PR protection. If this gap has an open PR, the work
    # is durable — leave the lease alone even if the claim is "expired" or
    # the originating PID is dead. The PR being open is enough signal
    # that another worker would just duplicate the work.
    if [[ -n "$gap_id" ]] && [[ -f "$REPO_ROOT/scripts/coord/lib/gap-pr-status.sh" ]]; then
        # shellcheck disable=SC1091
        source "$REPO_ROOT/scripts/coord/lib/gap-pr-status.sh"
        if gap_has_open_pr "$gap_id" 2>/dev/null; then
            _pr_nums="$(gap_open_pr_number "$gap_id" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
            echo "  SKIP claim reap (open PR #$_pr_nums exists for gap=$gap_id): $(basename "$claim_file")"
            printf '{"ts":"%s","kind":"stale_gap_lock_skipped","reason":"open_pr_exists","gap":"%s","prs":"%s","lock":"%s"}\n' \
                "$NOW_ISO" "$gap_id" "$_pr_nums" "$(basename "$claim_file")" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
            continue
        fi
    fi

    # INFRA-1236: heartbeat-liveness check BEFORE PID check. The PID
    # embedded in session_id is the bash subshell that ran `chump claim`,
    # which exits immediately — the long-running agent (claude-code,
    # fleet worker, etc.) has a different PID. INFRA-1208's PID check
    # therefore over-reaps any session with a fresh heartbeat.
    #
    # Rule: lease is alive if heartbeat_at is fresher than
    # CHUMP_LEASE_HEARTBEAT_TTL_S (default 600s). Falls through to PID +
    # TTL checks only when heartbeat is stale or missing. Combined liveness:
    #   alive == (heartbeat_fresh) OR (PID_alive) OR (TTL_not_reached)
    # Reap only when ALL three fail.
    heartbeat_at="$(python3 -c "
import json
try:
    d = json.load(open('$claim_file'))
    print(d.get('heartbeat_at', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"
    heartbeat_ttl="${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}"
    if [[ -n "$heartbeat_at" ]]; then
        heartbeat_epoch="$(python3 -c "
import datetime
try:
    dt = datetime.datetime.fromisoformat('$heartbeat_at'.replace('Z', '+00:00'))
    print(int(dt.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo "0")"
        if [[ "$heartbeat_epoch" -gt 0 ]]; then
            heartbeat_age=$((NOW_EPOCH_CLAIM - heartbeat_epoch))
            if [[ "$heartbeat_age" -lt "$heartbeat_ttl" ]]; then
                # Heartbeat is fresh — lease is alive. If the PID check
                # WOULD have reaped, emit a "protected" signal so we can
                # tune the TTL from telemetry.
                _maybe_dead_pid="$(printf '%s' "$session_id" | grep -oE '[0-9]+-[0-9]+$' | cut -d- -f1 2>/dev/null || echo "")"
                if [[ -n "$_maybe_dead_pid" ]] && ! ps -p "$_maybe_dead_pid" >/dev/null 2>&1; then
                    echo "  SKIP claim (heartbeat fresh ${heartbeat_age}s < ${heartbeat_ttl}s, pid=$_maybe_dead_pid would-reap): $(basename "$claim_file")"
                    printf '{"ts":"%s","kind":"stale_gap_lock_protected","event":"stale_gap_lock_protected","lock":"%s","session":"%s","gap":"%s","heartbeat_age_s":%d,"heartbeat_ttl_s":%d,"reason":"heartbeat_fresh"}\n' \
                        "$NOW_ISO" \
                        "$(basename "$claim_file")" \
                        "$session_id" "$gap_id" "$heartbeat_age" "$heartbeat_ttl" \
                        >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
                else
                    echo "  SKIP claim (heartbeat fresh ${heartbeat_age}s < ${heartbeat_ttl}s): $(basename "$claim_file")"
                fi
                continue
            fi
        fi
    fi

    # INFRA-1252: ghost-lease HANDOFF. If the dead session's gap branch has
    # commits beyond origin/main, broadcast STUCK (fleet) once + delay reap
    # by CHUMP_HANDOFF_ACK_WINDOW_S so a fresh worker can claim before we
    # forget the work. STUCK is used instead of HANDOFF for the fleet-broadcast
    # case because HANDOFF requires a named recipient. (When a specific
    # recipient can be chosen — e.g. via file-scope match — a follow-up gap
    # will switch to HANDOFF with --to.)
    if [[ -n "$gap_id" ]] && [[ -x "$REPO_ROOT/scripts/coord/broadcast.sh" ]]; then
        _handoff_stamp_dir="$LOCK_DIR/.handoff-pending"
        _handoff_stamp="$_handoff_stamp_dir/$gap_id.ts"
        _handoff_window="${CHUMP_HANDOFF_ACK_WINDOW_S:-900}"

        if [[ -f "$_handoff_stamp" ]]; then
            _hts="$(cat "$_handoff_stamp" 2>/dev/null || echo 0)"
            _hage=$((NOW_EPOCH_CLAIM - _hts))
            if [[ "$_hage" -lt "$_handoff_window" ]]; then
                echo "  SKIP claim reap (HANDOFF pending ${_hage}s/${_handoff_window}s): $(basename "$claim_file")"
                printf '{"ts":"%s","kind":"ghost_lease_handoff_pending","gap":"%s","session":"%s","age_s":%d,"window_s":%d}\n' \
                    "$NOW_ISO" "$gap_id" "$session_id" "$_hage" "$_handoff_window" \
                    >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
                continue
            fi
            rm -f "$_handoff_stamp" 2>/dev/null || true
        else
            _gap_lc="$(echo "$gap_id" | tr '[:upper:]' '[:lower:]')"
            _branch="chump/${_gap_lc}-claim"
            _repo_nwo=""
            if command -v gh >/dev/null 2>&1; then
                _repo_nwo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
            fi
            _commits_ahead=0
            if [[ -n "$_repo_nwo" ]]; then
                _commits_ahead="$(gh api "repos/$_repo_nwo/compare/main...$_branch" --jq '.ahead_by' 2>/dev/null || echo 0)"
                [[ -z "$_commits_ahead" ]] && _commits_ahead=0
            fi
            if [[ "$_commits_ahead" -ge 1 ]]; then
                _reason="ghost-lease (session=$session_id PID dead/TTL expired) — branch $_branch is $_commits_ahead commit(s) ahead of main. Picker: git fetch && git checkout $_branch && git rebase origin/main && push."
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo "  WOULD HANDOFF claim (commits=$_commits_ahead): $gap_id → fleet STUCK broadcast"
                else
                    mkdir -p "$_handoff_stamp_dir" 2>/dev/null || true
                    printf '%s' "$NOW_EPOCH_CLAIM" > "$_handoff_stamp"
                    "$REPO_ROOT/scripts/coord/broadcast.sh" --corr "$gap_id" STUCK "$gap_id" "$_reason" >/dev/null 2>&1 || true
                    printf '{"ts":"%s","kind":"ghost_lease_handoff","gap":"%s","session":"%s","commits_ahead":%d,"branch":"%s","ack_window_s":%d}\n' \
                        "$NOW_ISO" "$gap_id" "$session_id" "$_commits_ahead" "$_branch" "$_handoff_window" \
                        >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
                    echo "  HANDOFF claim (commits=$_commits_ahead): $gap_id → fleet (ack window ${_handoff_window}s before reap)"
                fi
                continue  # delay reap until ack window elapses
            fi
        fi
    fi

    # INFRA-2447: active bot-merge guard. Before reaping by PID-dead or TTL,
    # check whether bot-merge.sh is actively running for this gap. The PID in
    # session_id is the short-lived `chump claim` bash subshell (exits in <1s),
    # NOT the bot-merge process — so a dead claim PID does NOT mean bot-merge
    # is done. Two detection signals (either is sufficient to skip):
    #
    #   A) pgrep: a bot-merge.sh process whose command line contains --gap $gap_id
    #      is running right now.
    #   B) health file: a .chump-locks/bot-merge-*.health file exists whose
    #      gap_ids field contains $gap_id AND whose owning PID is still alive.
    #
    # When either fires, emit kind=reaper_skipped_active_bot_merge and continue.
    if [[ -n "$gap_id" ]]; then
        _bm_pid=""
        _bm_health_file=""

        # Signal A: pgrep for live bot-merge process referencing this gap_id.
        # INFRA-1658: no `printf | grep -q` — use process substitution.
        _bm_pgrep_out="$(pgrep -fl "bot-merge.*--gap.*${gap_id}" 2>/dev/null || true)"
        if [[ -n "$_bm_pgrep_out" ]]; then
            _bm_pid="$(echo "$_bm_pgrep_out" | awk '{print $1}' | head -1)"
        fi

        # Signal B: health file whose gap_ids contains gap_id and PID is alive.
        if [[ -z "$_bm_pid" ]]; then
            for _hf in "$LOCK_DIR"/bot-merge-*.health; do
                [[ -e "$_hf" ]] || continue
                _hf_gap_ids="$(python3 -c "
import json
try:
    d = json.load(open('$_hf'))
    print(d.get('gap_ids', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"
                # gap_ids is space-separated: "INFRA-2447 INFRA-2448"
                for _hf_gid in $_hf_gap_ids; do
                    if [[ "$_hf_gid" == "$gap_id" ]]; then
                        _hf_pid="$(python3 -c "
import json
try:
    d = json.load(open('$_hf'))
    print(d.get('pid', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"
                        if [[ -n "$_hf_pid" ]] && ps -p "$_hf_pid" >/dev/null 2>&1; then
                            _bm_pid="$_hf_pid"
                            _bm_health_file="$(basename "$_hf")"
                            break 2
                        fi
                    fi
                done
            done
        fi

        if [[ -n "$_bm_pid" ]]; then
            _bm_age_secs=""
            if [[ -n "$_bm_health_file" ]]; then
                # Approximate age from health file last-modified time.
                _hf_mtime="$(python3 -c "import os,time; print(int(time.time() - os.path.getmtime('$LOCK_DIR/$_bm_health_file')))" 2>/dev/null || echo "")"
                _bm_age_secs="${_hf_mtime:-}"
            fi
            echo "  SKIP claim (active bot-merge pid=$_bm_pid for gap=$gap_id): $(basename "$claim_file")"
            printf '{"ts":"%s","kind":"reaper_skipped_active_bot_merge","lock":"%s","session":"%s","gap":"%s","bot_merge_pid":%s,"age_secs":%s}\n' \
                "$NOW_ISO" \
                "$(basename "$claim_file")" \
                "$session_id" "$gap_id" "$_bm_pid" "${_bm_age_secs:-0}" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
            SKIPPED=$((SKIPPED+1))
            continue
        fi
    fi

    # INFRA-2447: heartbeat-TTL guard (AC step 3). If heartbeat_at is within
    # CHUMP_REAPER_LIVE_HEARTBEAT_S seconds (default 600 = 10min), treat as
    # live even when the claim PID is dead. This is complementary to INFRA-1236's
    # heartbeat_at check (which uses CHUMP_LEASE_HEARTBEAT_TTL_S) — both protect
    # against over-reaping; CHUMP_REAPER_LIVE_HEARTBEAT_S is the explicit AC knob.
    _reaper_hb_ttl="${CHUMP_REAPER_LIVE_HEARTBEAT_S:-600}"
    if [[ -n "$heartbeat_at" ]]; then
        _reaper_hb_epoch="$(python3 -c "
import datetime
try:
    dt = datetime.datetime.fromisoformat('$heartbeat_at'.replace('Z', '+00:00'))
    print(int(dt.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo "0")"
        if [[ "$_reaper_hb_epoch" -gt 0 ]]; then
            _reaper_hb_age=$((NOW_EPOCH_CLAIM - _reaper_hb_epoch))
            if [[ "$_reaper_hb_age" -lt "$_reaper_hb_ttl" ]]; then
                echo "  SKIP claim (reaper heartbeat guard: ${_reaper_hb_age}s < ${_reaper_hb_ttl}s): $(basename "$claim_file") [gap=$gap_id]"
                SKIPPED=$((SKIPPED+1))
                continue
            fi
        fi
    fi

    # INFRA-1208: PID-liveness check BEFORE TTL check. Sessions write 8h TTL
    # leases, but if a session crashes 30 min in, the existing TTL check
    # leaves the lease sitting for 7.5h+ — overnight accumulation of 14
    # dead leases observed 2026-05-14. session_id format is
    # claim-<gap>-<PID>-<EPOCH>. If PID is dead AND heartbeat is stale/missing
    # (gated above by INFRA-1236 + INFRA-2447), reap.
    claim_pid="$(printf '%s' "$session_id" | grep -oE '[0-9]+-[0-9]+$' | cut -d- -f1 2>/dev/null || echo "")"
    if [[ -n "$claim_pid" ]] && ! ps -p "$claim_pid" >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  WOULD REAP claim (pid=$claim_pid dead): $(basename "$claim_file") [gap=$gap_id]"
        else
            rm -f "$claim_file"
            echo "  REAPED claim (pid=$claim_pid dead): $(basename "$claim_file") [gap=$gap_id]"
            printf '{"ts":"%s","kind":"stale_gap_lock_reaped","event":"stale_gap_lock_reaped","lock":"%s","session":"%s","gap":"%s","reason":"pid_dead","pid":%d,"source":"claim_file"}\n' \
                "$NOW_ISO" \
                "$(basename "$claim_file")" \
                "$session_id" "$gap_id" "$claim_pid" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        fi
        CLAIM_REAPED=$((CLAIM_REAPED+1))
        continue
    fi

    if [[ "$expires_epoch" -gt 0 && "$expires_epoch" -lt "$NOW_EPOCH_CLAIM" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  WOULD REAP claim (expired $expires_at): $(basename "$claim_file") [gap=$gap_id]"
        else
            rm -f "$claim_file"
            echo "  REAPED claim (expired $expires_at): $(basename "$claim_file") [gap=$gap_id]"
            printf '{"ts":"%s","kind":"stale_gap_lock_reaped","event":"stale_gap_lock_reaped","lock":"%s","session":"%s","gap":"%s","reason":"expired","source":"claim_file"}\n' \
                "$NOW_ISO" \
                "$(basename "$claim_file")" \
                "$session_id" "$gap_id" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        fi
        CLAIM_REAPED=$((CLAIM_REAPED+1))
    fi
done

echo
echo "stale-gap-lock-reaper: reaped=$REAPED skipped=$SKIPPED errors=$ERRORS dry_run=$DRY_RUN db_reaped=$DB_REAPED claim_reaped=$CLAIM_REAPED"
