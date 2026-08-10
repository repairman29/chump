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
set -uo pipefail

HALT_AT="${CHUMP_BACKPRESSURE_HALT_AT:-6}"
RESUME_AT="${CHUMP_BACKPRESSURE_RESUME_AT:-3}"
WORKERS="${CHUMP_BACKPRESSURE_WORKERS:-1 2}"   # worker instance ids to govern
AUTON=/root/.chump/AUTONOMY_LEVEL
AMBIENT=/root/Projects/chump/.chump-locks/ambient.jsonl
ts(){ date -u +%FT%TZ; }
emit(){ printf '{"ts":"%s","kind":"%s","pile":%s,"halt_at":%s}\n' "$(ts)" "$1" "$2" "$HALT_AT" >> "$AMBIENT" 2>/dev/null || true; }

ME="$(gh api user --jq .login 2>/dev/null || echo repairman29)"
# depth of the JAM: open PRs that are BLOCKED or DIRTY (not merging)
pile="$(gh pr list --author "$ME" --state open --limit 60 --json mergeStateStatus \
        -q '[.[]|select(.mergeStateStatus=="BLOCKED" or .mergeStateStatus=="DIRTY")]|length' 2>/dev/null || echo 0)"
running="$(systemctl list-units 2>/dev/null | grep -c 'chump-worker@[0-9].*running')"
auton="$(cat "$AUTON" 2>/dev/null || echo 5)"

echo "[back-pressure $(ts)] stuck-pile=$pile (halt>=$HALT_AT resume<=$RESUME_AT) workers=$running autonomy=$auton"

if (( pile >= HALT_AT )) && (( running > 0 )); then
    echo "[back-pressure] JAM ($pile stuck) → HALTING production"
    for i in $WORKERS; do systemctl disable --now "chump-worker@${i}.service" >/dev/null 2>&1; done
    pkill -f 'scripts/dispatch/worker.sh' 2>/dev/null || true
    echo 0 > "$AUTON"
    emit production_halt "$pile"
    ( cd /root/Projects/chump && source scripts/coord/lib/notify-operator.sh && \
      CHUMP_NOTIFY_KIND=production_halt notify_operator \
      "🛑 **Production HALTED** — $pile PRs stuck unmerged (>=$HALT_AT). Workers stopped so the jam stops growing. Auto-resumes when the queue drains below $RESUME_AT." ) 2>/dev/null || true
    exit 0
fi

if (( pile <= RESUME_AT )) && { (( running == 0 )) || [[ "$auton" == "0" ]]; }; then
    echo "[back-pressure] queue drained ($pile stuck) → RESUMING production"
    echo 5 > "$AUTON"
    for i in $WORKERS; do systemctl enable --now "chump-worker@${i}.service" >/dev/null 2>&1; done
    emit production_resume "$pile"
    exit 0
fi

echo "[back-pressure] no change (pile in the hysteresis band or state already correct)"
