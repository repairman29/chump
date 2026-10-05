#!/usr/bin/env bash
# nba-dispatch-beat.sh — the AUTO-DISPATCH CONSUMER for the next-best-action router.
#
# EFFECTIVE-509 (+ a conservative first cut of EFFECTIVE-510): the piece that
# lets the OS AIM ITSELF between human check-ins, so it can carry multi-day
# stretches without a human dispatching every bet.
#
# THE PRODUCER (scripts/coord/next-best-action.sh, run on a 20-min timer) is
# ADVISORY: it COMPUTES an EV-ranked (value x P(success)) list of next-best-
# actions and writes ~/.chump/next-best-action.json, but it never acts. Until
# now a HUMAN read that file and dispatched each bet by hand — the single point
# of failure that stalls the whole fleet between check-ins.
#
# THIS CONSUMER closes that loop for a SMALL, SAFE, ALLOW-LISTED set of action-
# types only. It reads the TOP-ranked candidate and, if the action-type is on
# the auto allow-list, takes the appropriate REVERSIBLE action. For ANYTHING
# else — anything not on the list, ambiguous, or high-stakes — it does NOT act;
# it records a "needs-human" item (durable file + ambient event) so the bet
# surfaces in Jeff's digest for HIS call. Safe-by-default: better to defer too
# much than to auto-do something risky.
#
# ── THE AUTO ALLOW-LIST (SAFE = reversible, cheap, no money/publish/merge/destroy) ──
#   heal_organ           reset-failed + restart a DEAD manifest organ (systemd,
#                        watchdog pattern). Reversible; if the organ RELAPSES
#                        after an auto-heal it is NOT re-healed in a loop — it
#                        defers to the human instead (a relapse is a regression).
#   dispatch_worker_p0   "ensure workers are building": ensure the worker muscle
#   dispatch_worker_p1   (chump-*worker*.service) + farmer heartbeat are ACTIVE;
#                        start any that are down. RESPECTS the fleet-paused
#                        sentinel — if the operator paused the fleet, it DEFERS
#                        instead of overriding the pause. Reversible; creates no
#                        config, merges nothing.
#   wait_ci              benign no-op — CI is running; the right move is to do
#                        nothing and let it settle. Recorded, no side effect.
#
# ── NEVER AUTO-DONE (always defer to the human) ──
#   merge_pr, resolve_conflict, rebase_pr, rerun_stale, close_deep_red,
#   undraft_pr, fix_own_red, raise_faculty, AND any action-type not named on the
#   allow-list above. Merging PRs, closing/cutting PRs, dispatching model-
#   spending work, publishing, and changing standing config are all off-limits
#   to the autopilot — they surface as needs-human items for Jeff.
#
# IDEMPOTENT. It tracks the last bet it acted on (~/.chump/nba-dispatch-state.
# json). The SAME top bet is not re-decided within CHUMP_NBA_COOLDOWN_SEC
# (default 30 min), so a standing recommendation does not trigger repeated
# restarts or repeated digest spam. A healed organ that relapses within
# CHUMP_NBA_HEAL_RELAPSE_SEC (default 1h) escalates to the human rather than
# looping.
#
# OUTPUT / OBSERVABILITY, every cycle emits exactly one of:
#   kind=nba_dispatched            a real safe action was taken (with which)
#   kind=nba_deferred_to_human     the top bet is not auto-safe; recorded for Jeff
#   kind=nba_dispatch_skipped      idempotent-skip / stale input / no recs
#                                  (doubles as the organ heartbeat so a dark
#                                   consumer is itself visible)
# Deferrals ALSO append to ~/.chump/nba-needs-human.jsonl and refresh the
# snapshot ~/.chump/nba-needs-human.json that a digest/board can read.
#
# Usage:
#   scripts/coord/nba-dispatch-beat.sh            # read top bet, act-or-defer, emit
#   scripts/coord/nba-dispatch-beat.sh --dry-run  # decide + print, no mutation/emit
#
# Env:
#   CHUMP_NBA_OUT                producer json (default ~/.chump/next-best-action.json)
#   CHUMP_NBA_DISPATCH_STATE     idempotency state (default ~/.chump/nba-dispatch-state.json)
#   CHUMP_NBA_NEEDS_HUMAN_LOG    durable needs-human jsonl (default ~/.chump/nba-needs-human.jsonl)
#   CHUMP_NBA_NEEDS_HUMAN_SNAP   needs-human snapshot json (default ~/.chump/nba-needs-human.json)
#   CHUMP_NBA_COOLDOWN_SEC       don't re-decide the same bet within N s (default 1800)
#   CHUMP_NBA_HEAL_RELAPSE_SEC   relapse-after-heal → defer window (default 3600)
#   CHUMP_NBA_MAX_AGE_SEC        refuse to act on a producer file older than N s (default 3600)
#   CHUMP_NBA_DISPATCH_DRY_RUN   1 = dry-run (no mutation, no emit, no state write)
#   CHUMP_AMBIENT_LOG            ambient jsonl (default REPO/.chump-locks/ambient.jsonl)
#   Test hooks: CHUMP_NBA_SYSTEMCTL_BIN (stub systemctl), CHUMP_NBA_FLEET_PAUSE_FILE
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Anchor to the git toplevel of the WORKING DIR (the pr-pulse / NBA idiom): this
# organ reads GLOBAL fleet state (the ambient log lives under the main checkout).
REPO="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$DIR/../.." && pwd))"
# HOST-ASSUMPTION fix (mirrors faculty-collector / next-best-action): resolve the
# run-user's REAL home so gh/chump/almanac + ~/.chump reads land under systemd.
REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
[[ -n "${REAL_HOME:-}" && -d "$REAL_HOME" ]] && export HOME="$REAL_HOME"

NBA="${CHUMP_NBA_OUT:-$HOME/.chump/next-best-action.json}"
STATE="${CHUMP_NBA_DISPATCH_STATE:-$HOME/.chump/nba-dispatch-state.json}"
NEEDS_JSONL="${CHUMP_NBA_NEEDS_HUMAN_LOG:-$HOME/.chump/nba-needs-human.jsonl}"
NEEDS_SNAP="${CHUMP_NBA_NEEDS_HUMAN_SNAP:-$HOME/.chump/nba-needs-human.json}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
EMIT="$DIR/../dev/ambient-emit.sh"
COOLDOWN_SEC="${CHUMP_NBA_COOLDOWN_SEC:-1800}"
HEAL_RELAPSE_SEC="${CHUMP_NBA_HEAL_RELAPSE_SEC:-3600}"
MAX_AGE_SEC="${CHUMP_NBA_MAX_AGE_SEC:-3600}"
NODE="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" || "${CHUMP_NBA_DISPATCH_DRY_RUN:-0}" == "1" ]] && DRY_RUN=1

mkdir -p "$HOME/.chump"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%s)"

log() { echo "[nba-dispatch] $*"; }

# ── systemctl, with sudo -n elevation on owned nodes (RESILIENT-413 pattern) ──
# The management calls (reset-failed/restart/start) need root; on an OWNED node
# the organs run as User=jeff, and jeff has NOPASSWD sudo. Read-only calls work
# under sudo too, so wrapping the whole binary is safe.
SYSTEMCTL_BIN="${CHUMP_NBA_SYSTEMCTL_BIN:-systemctl}"
SYSTEMCTL_OK=0
if command -v "${SYSTEMCTL_BIN%% *}" >/dev/null 2>&1; then SYSTEMCTL_OK=1; fi
if [[ "$SYSTEMCTL_BIN" == "systemctl" && "${EUID:-$(id -u)}" -ne 0 ]] \
    && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  _sctl() { command sudo -n systemctl "$@"; }
  SYSTEMCTL_BIN="_sctl"
  log "not root — elevating systemctl management calls via 'sudo -n' (owned-node User=jeff, RESILIENT-413)"
fi
sctl() { "$SYSTEMCTL_BIN" "$@"; }

# ── emit one ambient event (unless dry-run) ──
emit() {
  local kind="$1"; shift
  [[ "$DRY_RUN" == "1" ]] && { log "(dry-run) would emit kind=$kind $*"; return 0; }
  [[ -x "$EMIT" ]] || return 0
  CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-nba-dispatch}" \
    "$EMIT" "$kind" "$@" 2>/dev/null || true
}

# ── record a needs-human item: durable jsonl + snapshot the digest can read ──
record_needs_human() {
  local action="$1" target="$2" ev="$3" p="$4" why="$5" need="$6" reason="$7"
  local rec
  rec="$(jq -n -c \
    --arg ts "$TS" --arg action "$action" --arg target "$target" \
    --arg ev "$ev" --arg p "$p" --arg why "$why" --arg need "$need" \
    --arg reason "$reason" --arg node "$NODE" '
    { ts:$ts, action:$action, target:$target,
      expected_value:($ev|tonumber? // $ev), p_success:($p|tonumber? // $p),
      why:$why, need_to_know:$need, deferred_reason:$reason, node:$node,
      decided_by:"nba-dispatch-beat" }' 2>/dev/null)"
  [[ -z "$rec" ]] && return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "(dry-run) would record needs-human: $rec"; return 0
  fi
  printf '%s\n' "$rec" >> "$NEEDS_JSONL"
  # Snapshot = the single current top deferral, for a digest/board to read.
  printf '%s' "$rec" | jq -c --arg ts "$TS" '{generated_at:$ts, top_deferral:.}' > "$NEEDS_SNAP" 2>/dev/null || true
}

# ── persist idempotency state ──
write_state() {
  local sig="$1" heals_json="$2"
  [[ "$DRY_RUN" == "1" ]] && return 0
  jq -n -c --arg ts "$TS" --arg sig "$sig" --argjson now "$NOW" --argjson heals "$heals_json" '
    { updated_at:$ts, last_sig:$sig, last_decision_ts:$now, heals:$heals }' > "$STATE" 2>/dev/null || true
}

# ── 0. read the producer board ──────────────────────────────────────────────
if [[ ! -f "$NBA" ]]; then
  log "no producer file at $NBA — nothing to consume."
  emit nba_dispatch_skipped reason=no_producer_file node="$NODE"
  exit 0
fi
NBA_JSON="$(cat "$NBA" 2>/dev/null)"
COUNT="$(printf '%s' "$NBA_JSON" | jq -r '.count // (.recommendations|length) // 0' 2>/dev/null || echo 0)"
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
if [[ "$COUNT" -eq 0 ]]; then
  log "producer board has 0 recommendations."
  emit nba_dispatch_skipped reason=no_recommendations node="$NODE"
  exit 0
fi

# staleness guard — never act on a stale picture (producer timer keeps it fresh).
GEN_AT="$(printf '%s' "$NBA_JSON" | jq -r '.generated_at // empty' 2>/dev/null)"
if [[ -n "$GEN_AT" ]]; then
  GEN_EPOCH="$(date -u -d "$GEN_AT" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$GEN_AT" +%s 2>/dev/null || echo 0)"
  if [[ "$GEN_EPOCH" =~ ^[0-9]+$ && "$GEN_EPOCH" -gt 0 ]]; then
    AGE=$(( NOW - GEN_EPOCH ))
    if [[ "$AGE" -gt "$MAX_AGE_SEC" ]]; then
      log "producer board is stale (${AGE}s > ${MAX_AGE_SEC}s) — refusing to act on a stale picture."
      emit nba_dispatch_skipped reason=stale_input age_sec="$AGE" node="$NODE"
      exit 0
    fi
  fi
fi

TOP="$(printf '%s' "$NBA_JSON" | jq -c '.recommendations[0]' 2>/dev/null)"
ACTION="$(printf '%s' "$TOP" | jq -r '.action // "unknown"')"
TARGET="$(printf '%s' "$TOP" | jq -r '.target // ""')"
EV="$(printf '%s' "$TOP" | jq -r '.expected_value // 0')"
P="$(printf '%s' "$TOP" | jq -r '.p_success // 0')"
WHY="$(printf '%s' "$TOP" | jq -r '.why // ""')"
NEED="$(printf '%s' "$TOP" | jq -r '.need_to_know // ""')"
SIG="${ACTION}|${TARGET}"

# ── 1. idempotency: don't re-decide the same top bet within the cooldown ─────
LAST_SIG=""; LAST_TS=0; HEALS='{}'
if [[ -f "$STATE" ]]; then
  LAST_SIG="$(jq -r '.last_sig // ""' "$STATE" 2>/dev/null)"
  LAST_TS="$(jq -r '.last_decision_ts // 0' "$STATE" 2>/dev/null)"
  HEALS="$(jq -c '.heals // {}' "$STATE" 2>/dev/null || echo '{}')"
  [[ "$LAST_TS" =~ ^[0-9]+$ ]] || LAST_TS=0
  [[ -n "$HEALS" ]] || HEALS='{}'
fi
if [[ "$SIG" == "$LAST_SIG" && $(( NOW - LAST_TS )) -lt "$COOLDOWN_SEC" ]]; then
  log "idempotent-skip: top bet '$SIG' already decided $(( NOW - LAST_TS ))s ago (< ${COOLDOWN_SEC}s cooldown)."
  emit nba_dispatch_skipped reason=cooldown sig="$SIG" node="$NODE"
  exit 0
fi

log "top bet: action=$ACTION target=$TARGET ev=$EV p=$P"

# ── 2. defer helper (records + emits, updates state) ─────────────────────────
defer() {
  local reason="$1"
  log "DEFER to human: $reason"
  record_needs_human "$ACTION" "$TARGET" "$EV" "$P" "$WHY" "$NEED" "$reason"
  emit nba_deferred_to_human action="$ACTION" target="$TARGET" ev="$EV" p="$P" reason="$reason" node="$NODE"
  write_state "$SIG" "$HEALS"
}

# dispatched helper (emits + updates state, optionally updated heals map)
dispatched() {
  local detail="$1" heals_override="${2:-$HEALS}"
  log "DISPATCHED: $ACTION -> $detail"
  emit nba_dispatched action="$ACTION" target="$TARGET" ev="$EV" p="$P" detail="$detail" node="$NODE"
  write_state "$SIG" "$heals_override"
}

# ── 3. the allow-list router ─────────────────────────────────────────────────
case "$ACTION" in

  heal_organ)
    UNIT="$TARGET"
    if [[ -z "$UNIT" ]]; then defer "heal_organ with empty target"; exit 0; fi
    if [[ "$SYSTEMCTL_OK" -ne 1 ]]; then defer "no systemctl on this node ($NODE) — cannot heal $UNIT"; exit 0; fi
    # relapse guard: if we healed this unit recently and it is failed AGAIN,
    # that is a regression, not a flake — hand it to the human, don't loop.
    LAST_HEAL="$(printf '%s' "$HEALS" | jq -r --arg u "$UNIT" '.[$u] // 0' 2>/dev/null)"
    [[ "$LAST_HEAL" =~ ^[0-9]+$ ]] || LAST_HEAL=0
    # `systemctl is-failed` PRINTS the active state ("failed" iff the unit is in
    # the failed state). Read the printed string, not the exit code, so pipefail
    # + is-failed's nonzero exit can't corrupt the check.
    ISF_STATE="$(sctl is-failed "$UNIT" 2>/dev/null || true)"
    if [[ "$ISF_STATE" == "failed" ]]; then IS_FAILED=1; else IS_FAILED=0; fi
    if [[ "$IS_FAILED" -ne 1 ]]; then
      dispatched "organ $UNIT already recovered (not failed) — no restart needed"
      exit 0
    fi
    if [[ "$LAST_HEAL" -gt 0 && $(( NOW - LAST_HEAL )) -lt "$HEAL_RELAPSE_SEC" ]]; then
      defer "organ $UNIT RELAPSED $(( NOW - LAST_HEAL ))s after an auto-heal — a regression, needs a human (not an auto-restart loop)"
      exit 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
      log "(dry-run) would: sctl reset-failed $UNIT && sctl restart $UNIT"
      dispatched "(dry-run) reset-failed+restart $UNIT"
      exit 0
    fi
    OK=1
    sctl reset-failed "$UNIT" 2>&1 | sed 's/^/[nba-dispatch]   /' || OK=0
    sctl restart "$UNIT" 2>&1 | sed 's/^/[nba-dispatch]   /' || OK=0
    NEW_HEALS="$(printf '%s' "$HEALS" | jq -c --arg u "$UNIT" --argjson now "$NOW" '.[$u]=$now' 2>/dev/null || echo "$HEALS")"
    if [[ "$OK" -eq 1 ]]; then
      dispatched "reset-failed+restart $UNIT (dead manifest organ revived)" "$NEW_HEALS"
    else
      # the restart itself failed — that is a genuinely stuck organ; page the human.
      record_needs_human "$ACTION" "$TARGET" "$EV" "$P" "$WHY" "$NEED" "auto reset-failed+restart of $UNIT FAILED — needs a human"
      emit nba_deferred_to_human action="$ACTION" target="$TARGET" reason="restart_failed:$UNIT" node="$NODE"
      write_state "$SIG" "$NEW_HEALS"
    fi
    ;;

  dispatch_worker_p0|dispatch_worker_p1|ensure_workers)
    if [[ "$SYSTEMCTL_OK" -ne 1 ]]; then defer "no systemctl on this node ($NODE) — cannot ensure workers"; exit 0; fi
    # RESPECT the operator pause: never override a deliberately paused fleet.
    PAUSE_FILE="${CHUMP_NBA_FLEET_PAUSE_FILE:-}"
    PAUSED=0
    for pf in "$PAUSE_FILE" "$REPO/.chump/fleet-paused" "$HOME/.chump/fleet-paused"; do
      [[ -n "$pf" && -f "$pf" ]] && PAUSED=1
    done
    if [[ "$PAUSED" -eq 1 ]]; then
      defer "fleet is PAUSED (fleet-paused sentinel present) — not auto-starting workers; a human owns un-pausing"
      exit 0
    fi
    # "Ensure workers are building" — the CONSERVATIVE reading:
    #   * Revive genuinely FAILED worker/farmer muscle (reset-failed + start) —
    #     a failed worker is unambiguously broken, so a restart is safe + right.
    #   * Ensure the farmer HEARTBEAT TIMER is active (drives the gate workers
    #     read) — start the timer if it is enabled-but-inactive.
    # It deliberately does NOT force-start units that are merely `inactive`: a
    # timer-driven oneshot is normally inactive between ticks, and an autoscaled
    # worker may be deliberately down — fighting either would be churn, not help.
    STARTED=(); FAILED_REVIVED=(); ACTIVE=0; IDLE=0
    mapfile -t WSVCS < <(sctl list-units --type=service --all --no-legend 'chump-*worker*.service' 'chump-*farmer*.service' 2>/dev/null | awk '{print $1}' | sed 's/^\xe2\x97\x8f//; s/^●//' | grep -v '^$' | sort -u)
    if [[ "${#WSVCS[@]}" -eq 0 ]]; then
      defer "no chump worker/farmer service units found on $NODE — cannot ensure workers building (node may not be a muscle node)"
      exit 0
    fi
    for u in "${WSVCS[@]}"; do
      [[ -z "$u" ]] && continue
      if sctl is-active "$u" >/dev/null 2>&1; then ACTIVE=$(( ACTIVE + 1 )); continue; fi
      u_state="$(sctl is-failed "$u" 2>/dev/null || true)"
      if [[ "$u_state" == "failed" ]]; then
        if [[ "$DRY_RUN" == "1" ]]; then log "(dry-run) would reset-failed+start FAILED $u"; FAILED_REVIVED+=("$u"); continue; fi
        sctl reset-failed "$u" >/dev/null 2>&1 || true
        if sctl start "$u" >/dev/null 2>&1; then FAILED_REVIVED+=("$u"); fi
      else
        IDLE=$(( IDLE + 1 ))  # inactive-but-not-failed: leave alone (oneshot/autoscaled)
      fi
    done
    # farmer heartbeat timer(s): if enabled but not active, (re)start the TIMER.
    mapfile -t FTIMERS < <(sctl list-unit-files --no-legend 'chump-*farmer*.timer' 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    for t in "${FTIMERS[@]}"; do
      [[ -z "$t" ]] && continue
      sctl is-enabled "$t" >/dev/null 2>&1 || continue
      if sctl is-active "$t" >/dev/null 2>&1; then ACTIVE=$(( ACTIVE + 1 )); continue; fi
      if [[ "$DRY_RUN" == "1" ]]; then log "(dry-run) would start enabled-inactive $t"; STARTED+=("$t"); continue; fi
      sctl reset-failed "$t" >/dev/null 2>&1 || true
      if sctl start "$t" >/dev/null 2>&1; then STARTED+=("$t"); fi
    done
    ACTED=("${FAILED_REVIVED[@]}" "${STARTED[@]}")
    if [[ "${#ACTED[@]}" -gt 0 ]]; then
      dispatched "ensured workers building — revived/started ${#ACTED[@]} unit(s): ${ACTED[*]} (${ACTIVE} already active, ${IDLE} idle-left-alone)"
    else
      dispatched "workers already building — ${ACTIVE} worker/farmer unit(s) active, ${IDLE} idle-left-alone, nothing broken (no-op)"
    fi
    ;;

  wait_ci)
    # benign no-op: CI is running; the correct move is to do nothing and let it
    # settle. Recorded for the heartbeat, zero side effect.
    dispatched "no-op — CI is running on $TARGET; nothing to do but let it settle"
    ;;

  *)
    # NOT on the allow-list → defer to the human. Covers merge_pr,
    # resolve_conflict, rebase_pr, rerun_stale, close_deep_red, undraft_pr,
    # fix_own_red, raise_faculty, and any future/unknown action-type.
    defer "action-type '$ACTION' is not on the auto-safe allow-list (heal_organ / dispatch_worker_p* / wait_ci) — high-stakes or irreversible, so it is Jeff's call"
    ;;
esac

exit 0
