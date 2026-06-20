#!/usr/bin/env bash
# conductor-loop.sh — EFFECTIVE-088 minimal self-rescue conductor ("the empty chair").
#
# An AUTONOMOUS loop that DETECTS a wedged fleet and DRIVES a self-rescue through
# the consensus bus, obeying the autonomy dial + kill switch. This is the slice-(a)
# replacement for the human-run conductor: the role I (an Opus session) played by
# hand during the 2026-06-15..20 outage, now performed by chump itself.
#
# WHY an objection-window instead of a quorum gate (verified 2026-06-20):
#   The consensus deliberator TALLIES correctly, but there is no autonomous
#   curator-voter population (`broadcast` finds 0 .curator-opus-*.lock files), so
#   real proposals die at NO_QUORUM. For SELF-RESCUE — non-halt-class actions like
#   unpause/restart that "no solo outages" (CREDIBLE-090) does NOT forbid — the
#   conductor PROPOSES, opens an objection window, and acts UNLESS a -1 vote vetoes.
#   It still uses the consensus bus (anyone may veto); it just doesn't BLOCK on a
#   quorum that structurally cannot form until autonomous voters exist.
#   Halt-class actions (stop-fleet, page) are out of scope here — they still need
#   real quorum/operator.
#
# SAFETY: dry-run by default. Set CHUMP_CONDUCTOR_ACT=1 to actually execute rescues.
# Obeys ~/.chump/AUTONOMY_LEVEL (0 = stopped → stand down) and the fleet kill switch.
#
# Rust-First-Bypass: v1 proof-of-loop wiring existing CLIs (git + chump + broadcast.sh
# + launchctl); the durable daemon is the Rust port tracked under EFFECTIVE-088.
set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
AL_FILE="${CHUMP_AUTONOMY_LEVEL_FILE:-${HOME}/.chump/AUTONOMY_LEVEL}"
PAUSE_FILE="${CHUMP_FLEET_PAUSE_FILE:-$REPO_ROOT/.chump/fleet-paused}"
GRACE_S="${CHUMP_CONDUCTOR_GRACE_S:-300}"
ACT="${CHUMP_CONDUCTOR_ACT:-0}"          # 0 = dry-run (default), 1 = execute
NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { printf '{"ts":"%s","kind":"%s","source":"conductor",%s}\n' "$(NOW)" "$1" "$2" >> "$AMBIENT" 2>/dev/null || true; }

# ── 1. kill switch + autonomy dial ───────────────────────────────────────────
al=0; [[ -r "$AL_FILE" ]] && al="$(tr -dc '0-9' < "$AL_FILE" 2>/dev/null)"; al="${al:-0}"
if [[ "$al" -eq 0 ]]; then
    echo "[conductor] autonomy dial = 0 (stopped) — standing down"
    emit conductor_tick '"state":"halted","reason":"autonomy_level=0"'
    exit 0
fi

# ── 2. detect wedge by GROUND TRUTH (not detector-trust — CREDIBLE-090) ───────
recent_merges=$(cd "$REPO_ROOT" && git log origin/main --oneline --since='3 hours ago' 2>/dev/null | wc -l | tr -d ' ')
pickable=$(chump gap list --status open 2>/dev/null | grep -cE 'P0|P1' 2>/dev/null); pickable=${pickable:-0}
paused=0; [[ -f "$PAUSE_FILE" ]] && paused=1
wedged=0; reason=""
if [[ "${recent_merges:-0}" -eq 0 && "${pickable:-0}" -gt 0 ]]; then
    wedged=1; reason="no merges in 3h while ${pickable} P0/P1 gaps pickable"
fi
if [[ "$paused" -eq 1 ]]; then
    wedged=1; reason="${reason:+$reason; }fleet-paused sentinel present"
fi

if [[ "$wedged" -eq 0 ]]; then
    echo "[conductor] HEALTHY — merges_3h=${recent_merges}, pickable=${pickable}, paused=${paused}. No action."
    emit conductor_tick '"state":"healthy","merges_3h":'"${recent_merges:-0}"',"pickable":'"${pickable:-0}"
    exit 0
fi

# ── 3. propose self-rescue on the consensus bus ──────────────────────────────
corr="conductor-rescue-$(NOW | tr -d ':-')"
echo "[conductor] WEDGE DETECTED: ${reason}"
echo "[conductor] proposing self-rescue (corr=${corr}, objection window ${GRACE_S}s)"
bash "$REPO_ROOT/scripts/coord/broadcast.sh" --corr-id "$corr" FEEDBACK proposal "$corr" \
    "Self-rescue: ${reason}. Action: clear stale fleet-paused + kick ci-health-gate + ensure workers. Veto with -1 within ${GRACE_S}s." >/dev/null 2>&1 || true
emit conductor_proposed '"corr_id":"'"$corr"'","reason":"'"$reason"'","grace_s":'"$GRACE_S"

# ── 4. objection window: a single -1 vote vetoes the rescue ──────────────────
sleep "${CHUMP_CONDUCTOR_GRACE_OVERRIDE_S:-$GRACE_S}"
objections=$(grep -F "$corr" "$AMBIENT" 2>/dev/null | grep -cE '"vote":-1|"preference".*"-1"|"value":-1' 2>/dev/null); objections=${objections:-0}

# ── 5. decide + (gated) act ──────────────────────────────────────────────────
if [[ "${objections:-0}" -gt 0 ]]; then
    echo "[conductor] ${objections} objection(s) — standing down + escalating (no override of a veto)"
    emit conductor_standdown '"corr_id":"'"$corr"'","objections":'"$objections"
    exit 0
fi
if [[ "$ACT" -eq 1 ]]; then
    echo "[conductor] no objection — EXECUTING self-rescue"
    if [[ -f "$PAUSE_FILE" ]]; then mv "$PAUSE_FILE" "${PAUSE_FILE}.conductor-cleared-$(date -u +%s)" 2>/dev/null || true; fi
    launchctl kickstart "gui/$(id -u 2>/dev/null)/com.chump.ci-health-gate" 2>/dev/null || true
    emit conductor_acted '"corr_id":"'"$corr"'","action":"cleared_pause+kicked_gate","reason":"'"$reason"'"'
    echo "[conductor] self-rescue executed."
else
    echo "[conductor] DRY-RUN (CHUMP_CONDUCTOR_ACT=0): would clear pause + kick ci-health-gate. No action taken."
    emit conductor_dryrun '"corr_id":"'"$corr"'","would":"clear_pause+kick_gate","reason":"'"$reason"'"'
fi
