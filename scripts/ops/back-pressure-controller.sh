#!/usr/bin/env bash
# back-pressure-controller.sh — RESILIENT: production flow-control (circuit-breaker).
#
# WHY (operator, 2026-08-10): "When things start to pile up like this, we need to
# shut down production so we don't keep piling on shit that we have to rebase a
# million times." Every other daemon PUSHES work through; none stops the LINE when
# the downstream jams. This is that governor: tie worker production to the depth of
# the unmerged-but-STUCK PR queue.
#
#   pile >= HALT_AT   → HALT production (disable worker units + autonomy 0), page.
#   pile <= RESUME_AT → RESUME production (autonomy up + start worker units).
#
# "Stuck" = open PR that is BLOCKED or DIRTY (not merging). Fresh PRs mid-CI don't
# count — only jams do. Idempotent; safe to run on a timer.
#
# ── RESILIENT-324 (2026-08-14): the permanent-halt DEAD-ZONE fix ──────────────
# The original breaker had a fatal gap: it HALTS at pile>=HALT_AT (6) and only
# RESUMES at pile<=RESUME_AT (3). The 3<pile<6 band (4–5) was "no change" — pure
# hysteresis to stop flapping. But the jam is usually CONFLICTING PRs, which the
# armed-rebaser CANNOT drain (it only rebases *behind* PRs). So the pile drained
# partway to 4–5, parked in the dead-zone, and the fleet stayed HALTED forever
# (workers disabled, autonomy 0) with NO auto-recovery — every hand-restart got
# re-killed on the next tick. That deadlocked the fleet for hours.
#
# The fix here is a STUCK-HALTED TIMEOUT ESCAPE that preserves the breaker's real
# intent (halt hard at a genuine 6+ jam, don't flap at the boundary) while making
# a permanent halt impossible:
#
#   • Fast resume (unchanged): pile<=RESUME_AT while halted → resume immediately.
#   • Escape resume (NEW): if the fleet is halted (workers down OR autonomy 0)
#     AND pile < HALT_AT — i.e. NOT a genuine 6+ jam — start a stuck-clock. Once
#     we have been stranded below HALT_AT for STUCK_ESCAPE_SECS (default 30 min /
#     ~6 ticks), RESUME regardless of the hysteresis band. A pile that is not a
#     real jam must never keep the line dead.
#
# The escape pairs with the rot-reaper organ (scripts/ops/rot-reaper.sh), which
# actively drains the CONFLICTING PRs that caused the partial drain; together they
# guarantee the fleet self-heals from this jam with no human babysitter.
set -uo pipefail

HALT_AT="${CHUMP_BACKPRESSURE_HALT_AT:-6}"
RESUME_AT="${CHUMP_BACKPRESSURE_RESUME_AT:-3}"
# RESILIENT-324: how long the fleet may sit halted below HALT_AT before the
# escape forces a resume. Default 30 min (≈6 five-minute ticks).
STUCK_ESCAPE_SECS="${CHUMP_BACKPRESSURE_STUCK_ESCAPE_SECS:-1800}"
WORKERS="${CHUMP_BACKPRESSURE_WORKERS:-1 2}"   # worker instance ids to govern
# Paths are env-overridable so the breaker is portable to non-root nodes
# (docs/process/LINUX_NODE_ONBOARDING.md) and testable off-host.
AUTON="${CHUMP_AUTON_FILE:-/root/.chump/AUTONOMY_LEVEL}"
HALT_SINCE="${CHUMP_HALT_SINCE_FILE:-/root/.chump/backpressure_halt_since}"   # RESILIENT-324 stuck-clock
AMBIENT="${CHUMP_AMBIENT_FILE:-/root/Projects/chump/.chump-locks/ambient.jsonl}"
ts(){ date -u +%FT%TZ; }
emit(){ printf '{"ts":"%s","kind":"%s","pile":%s,"halt_at":%s}\n' "$(ts)" "$1" "$2" "$HALT_AT" >> "$AMBIENT" 2>/dev/null || true; }

# RESILIENT-324: a `chattr +i` lock on AUTONOMY_LEVEL once broke the breaker's
# autonomy writes ("Operation not permitted") and crashed the tick, so a halt
# could not clear. Tolerate a write failure gracefully — log and continue —
# rather than letting `set -e`-style failure abort the recovery path.
write_auton(){
    if ! echo "$1" > "$AUTON" 2>/dev/null; then
        echo "[back-pressure] WARN: could not write autonomy=$1 to $AUTON (locked/immutable?) — continuing" >&2
        return 1
    fi
    return 0
}

ME="$(gh api user --jq .login 2>/dev/null || echo repairman29)"
# depth of the JAM: open PRs that are BLOCKED or DIRTY (not merging).
# CHUMP_BACKPRESSURE_PILE / _RUNNING are TEST HOOKS: when set they bypass the
# live gh / systemctl probes so the halt/resume logic can be exercised in CI.
if [[ -n "${CHUMP_BACKPRESSURE_PILE:-}" ]]; then
    pile="$CHUMP_BACKPRESSURE_PILE"
else
    pile="$(gh pr list --author "$ME" --state open --limit 60 --json mergeStateStatus \
            -q '[.[]|select(.mergeStateStatus=="BLOCKED" or .mergeStateStatus=="DIRTY")]|length' 2>/dev/null || echo 0)"
fi
if [[ -n "${CHUMP_BACKPRESSURE_RUNNING:-}" ]]; then
    running="$CHUMP_BACKPRESSURE_RUNNING"
else
    running="$(systemctl list-units 2>/dev/null | grep -c 'chump-worker@[0-9].*running')"
fi
auton="$(cat "$AUTON" 2>/dev/null || echo 5)"
halted=0; { (( running == 0 )) || [[ "$auton" == "0" ]]; } && halted=1

echo "[back-pressure $(ts)] stuck-pile=$pile (halt>=$HALT_AT resume<=$RESUME_AT) workers=$running autonomy=$auton halted=$halted"

resume_now(){  # reason
    echo "[back-pressure] $1 → RESUMING production"
    write_auton 5 || true
    for i in $WORKERS; do systemctl enable --now "chump-worker@${i}.service" >/dev/null 2>&1; done
    rm -f "$HALT_SINCE" 2>/dev/null || true   # RESILIENT-324: clear stuck-clock
    emit production_resume "$pile"
}

# ── genuine 6+ jam → HALT ─────────────────────────────────────────────────────
if (( pile >= HALT_AT )) && (( running > 0 )); then
    echo "[back-pressure] JAM ($pile stuck) → HALTING production"
    for i in $WORKERS; do systemctl disable --now "chump-worker@${i}.service" >/dev/null 2>&1; done
    pkill -f 'scripts/dispatch/worker.sh' 2>/dev/null || true
    write_auton 0 || true
    date +%s > "$HALT_SINCE" 2>/dev/null || true   # RESILIENT-324: start stuck-clock
    emit production_halt "$pile"
    ( cd /root/Projects/chump && source scripts/coord/lib/notify-operator.sh && \
      CHUMP_NOTIFY_KIND=production_halt notify_operator \
      "🛑 **Production HALTED** — $pile PRs stuck unmerged (>=$HALT_AT). Workers stopped so the jam stops growing. Auto-resumes when the queue drains below $RESUME_AT or after the stuck-escape timeout." ) 2>/dev/null || true
    exit 0
fi

# ── fast resume: genuinely drained ───────────────────────────────────────────
if (( pile <= RESUME_AT )) && (( halted == 1 )); then
    resume_now "queue drained ($pile stuck)"
    exit 0
fi

# ── RESILIENT-324 escape: halted but NOT a genuine jam (pile < HALT_AT) ───────
# The dead-zone killer. If the fleet is down while the pile is below HALT_AT,
# this is NOT the 6+ jam the breaker exists to hold — it is the CONFLICTING-jam
# residue the rebaser can't drain. Never let it strand the line: start a clock,
# and once we've been stuck this way past STUCK_ESCAPE_SECS, force a resume.
if (( halted == 1 )) && (( pile < HALT_AT )); then
    now="$(date +%s)"
    since="$(cat "$HALT_SINCE" 2>/dev/null || echo "")"
    if [[ -z "$since" || ! "$since" =~ ^[0-9]+$ ]]; then
        # No stuck-clock yet (e.g. halted by something other than this breaker,
        # or the file was cleared) — start it now so the escape can fire later.
        echo "$now" > "$HALT_SINCE" 2>/dev/null || true
        since="$now"
    fi
    elapsed=$(( now - since ))
    if (( elapsed >= STUCK_ESCAPE_SECS )); then
        emit backpressure_stuck_escape "$pile"
        resume_now "STUCK-HALTED ${elapsed}s below HALT_AT with pile=$pile (not a real jam) — dead-zone escape"
        exit 0
    fi
    echo "[back-pressure] halted with pile=$pile (< $HALT_AT): stuck ${elapsed}s/${STUCK_ESCAPE_SECS}s before escape-resume"
    exit 0
fi

# Healthy running state, or a real jam already being held. Keep the stuck-clock
# clear so a future halt starts a fresh window.
[[ "$halted" == "0" ]] && rm -f "$HALT_SINCE" 2>/dev/null || true
echo "[back-pressure] no change (running healthy, or pile>=HALT_AT already held)"
