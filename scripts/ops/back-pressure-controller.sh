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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HALT_AT="${CHUMP_BACKPRESSURE_HALT_AT:-6}"
RESUME_AT="${CHUMP_BACKPRESSURE_RESUME_AT:-3}"
# RESILIENT-324: how long the fleet may sit halted below HALT_AT before the
# escape forces a resume. Default 30 min (≈6 five-minute ticks).
STUCK_ESCAPE_SECS="${CHUMP_BACKPRESSURE_STUCK_ESCAPE_SECS:-1800}"
# ── RESILIENT-308 (2026-08-14): systemic-red awareness ────────────────────────
# The RESILIENT-324 escape stopped a PERMANENT deadlock, but the breaker still
# HALTS spuriously the moment a shared/flaky failure reds >=HALT_AT open PRs at
# once — e.g. a cancelled audit-shard or the dial_zero_halts env-race (RESILIENT-224)
# turns main AND every open PR RED on the SAME required check. Those PRs are
# VICTIMS of flaky CI, not a genuine merge jam, yet the old pile counted them and
# halted the fleet ~6× (chairman had to hand-resume each time).
#
# Fix: before halting, classify the stuck pile into
#   • GENUINE jam  — DIRTY/CONFLICTING (real merge conflicts) + PRs whose failing
#                    checks are PR-SPECIFIC (red here, not red on main or peers).
#   • SYSTEMIC-RED — a required check failing identically on origin/main HEAD, OR
#                    the SAME check failing across >= SHARED_MIN open PRs (a shared
#                    /flaky failure, not independent per-PR bugs).
# Only GENUINE depth drives HALT/RESUME/escape. Systemic victims are excluded from
# the count and instead trigger a loud `systemic_red` signal + a flake auto-rerun
# (scripts/ops/ci-flake-rerun.sh). This preserves the breaker's real intent (halt
# when work genuinely can't merge) while it stops firing on flaky/shared red.
SHARED_MIN="${CHUMP_BACKPRESSURE_SHARED_MIN:-3}"   # same check red on >=N PRs ⇒ systemic
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

# ── RESILIENT-308: the classifier ─────────────────────────────────────────────
# Reads two JSON blobs and prints "GENUINE SYSTEMIC" plus, on a 3rd line, a
# space-separated list of the systemic PR numbers (for the rerun trigger).
#   $1 = PR facts   : [{"number":N,"mergeStateStatus":"BLOCKED|DIRTY|...",
#                       "checks":[{"name":"audit","conclusion":"CANCELLED"}, ...]}]
#   $2 = main facts : [{"name":"audit","conclusion":"FAILURE"}, ...]  (origin/main HEAD)
# A BLOCKED PR with no failing check is mid-flight (skipped, counted as neither).
# A PR is SYSTEMIC iff EVERY one of its failing checks is explained by a systemic
# cause (also-failing-on-main, or shared across >= SHARED_MIN PRs) — one genuinely
# PR-specific red makes it a GENUINE jam (fail-closed toward halting).
classify_pile() {
    CLASSIFY_PRFACTS="$1" CLASSIFY_MAINFACTS="$2" SHARED_MIN="$SHARED_MIN" \
    python3 - <<'PY'
import json, os
FAIL = {"FAILURE","CANCELLED","TIMED_OUT","ERROR","STARTUP_FAILURE","ACTION_REQUIRED"}
shared_min = int(os.environ.get("SHARED_MIN", "3"))
def load(v):
    try: return json.loads(v) if v.strip() else []
    except Exception: return []
prfacts   = load(os.environ.get("CLASSIFY_PRFACTS", ""))
mainfacts = load(os.environ.get("CLASSIFY_MAINFACTS", ""))

main_failing = { (c.get("name") or c.get("context") or "")
                 for c in mainfacts
                 if (c.get("conclusion") or "").upper() in FAIL }
main_failing.discard("")

# First pass: per-PR failing-check sets + global per-check PR counts.
pr_failing = {}          # number -> set(check names)
genuine = 0
from collections import Counter
check_pr_count = Counter()
for p in prfacts:
    mss = (p.get("mergeStateStatus") or "").upper()
    if mss in ("DIRTY", "CONFLICTING"):
        genuine += 1                     # real merge conflict — always a genuine jam
        continue
    if mss != "BLOCKED":
        continue                         # BEHIND/UNSTABLE/CLEAN/UNKNOWN: not stuck
    failing = { (c.get("name") or c.get("context") or "")
                for c in (p.get("checks") or [])
                if (c.get("conclusion") or "").upper() in FAIL }
    failing.discard("")
    if not failing:
        continue                         # blocked but nothing failed → mid-flight
    n = p.get("number")
    pr_failing[n] = failing
    for name in failing:
        check_pr_count[name] += 1

# Second pass: classify each BLOCKED-with-failures PR.
systemic_prs = []
for n, failing in pr_failing.items():
    systemic = True
    for name in failing:
        if name in main_failing:
            continue                     # same check red on main → systemic cause
        if check_pr_count[name] >= shared_min:
            continue                     # same check red across many PRs → shared/flaky
        systemic = False                 # a genuinely PR-specific red
        break
    if systemic:
        systemic_prs.append(n)
    else:
        genuine += 1

print(f"{genuine} {len(systemic_prs)}")
print(" ".join(str(x) for x in systemic_prs))
PY
}

# ── RESILIENT-308: systemic-red action — signal loudly + rerun the flakes ─────
# Never halts on these PRs; instead emits a distinct loud `systemic_red` ambient
# signal (RESILIENT-326 governance) and kicks the ci-flake-rerun organ so the
# cancelled-shard / env-race victims get reliably rerun to green. Best-effort and
# cooldown-guarded (the organ dedups per run-id), so calling it every tick is safe.
trigger_systemic_rerun() { # $1 = systemic count, $2 = systemic PR numbers
    local n="$1" prs="$2"
    echo "[back-pressure] SYSTEMIC-RED: $n PR(s) blocked by shared/flaky red (main-gate or same-check-across-PRs) — NOT halting on them; re-running the flaky checks [PRs: ${prs:-none}]"
    emit systemic_red "$n"
    [[ "${CHUMP_BACKPRESSURE_NO_RERUN:-0}" == "1" ]] && return 0
    if [[ -n "${CHUMP_BACKPRESSURE_RERUN_CMD:-}" ]]; then
        eval "$CHUMP_BACKPRESSURE_RERUN_CMD" || true
    elif [[ -x "$SCRIPT_DIR/ci-flake-rerun.sh" ]]; then
        nohup bash "$SCRIPT_DIR/ci-flake-rerun.sh" >/dev/null 2>&1 &
    fi
    return 0
}

ME="$(gh api user --jq .login 2>/dev/null || echo repairman29)"

# ── depth of the JAM — RESILIENT-308: GENUINE vs SYSTEMIC ─────────────────────
# `genuine` (real merge conflicts + PR-specific real failures) is the number that
# drives HALT/RESUME/escape; `systemic` (flaky/shared victims) is spared + rerun.
# `raw_pile` (all BLOCKED+DIRTY) is kept only for the human-readable log line.
# TEST HOOKS, in precedence order:
#   CHUMP_BACKPRESSURE_GENUINE / _SYSTEMIC — inject the classified counts directly.
#   CHUMP_BACKPRESSURE_PRFACTS (+_MAINFACTS) — feed the REAL classifier PR facts.
#   CHUMP_BACKPRESSURE_PILE — legacy hook: whole pile treated as genuine jam
#                             (systemic=0) — preserves the RESILIENT-324 behavior.
# _RUNNING likewise bypasses the live systemctl probe.
systemic=0; systemic_prs=""
if [[ -n "${CHUMP_BACKPRESSURE_GENUINE:-}" ]]; then
    genuine="$CHUMP_BACKPRESSURE_GENUINE"
    systemic="${CHUMP_BACKPRESSURE_SYSTEMIC:-0}"
    raw_pile=$(( genuine + systemic ))
elif [[ -n "${CHUMP_BACKPRESSURE_PRFACTS:-}" ]]; then
    _pf="$(cat "$CHUMP_BACKPRESSURE_PRFACTS" 2>/dev/null || echo '[]')"
    _mf="$(cat "${CHUMP_BACKPRESSURE_MAINFACTS:-/dev/null}" 2>/dev/null || echo '[]')"
    _cls="$(classify_pile "$_pf" "$_mf")"
    genuine="$(echo "$_cls" | sed -n '1p' | awk '{print $1}')"
    systemic="$(echo "$_cls" | sed -n '1p' | awk '{print $2}')"
    systemic_prs="$(echo "$_cls" | sed -n '2p')"
    genuine="${genuine:-0}"; systemic="${systemic:-0}"
    raw_pile=$(( genuine + systemic ))
elif [[ -n "${CHUMP_BACKPRESSURE_PILE:-}" ]]; then
    genuine="$CHUMP_BACKPRESSURE_PILE"; systemic=0; raw_pile="$genuine"
else
    # Live: one PR-list call carries mergeStateStatus + statusCheckRollup; a second
    # cheap call reads origin/main HEAD's check-runs. Classify locally.
    _pf="$(gh pr list --author "$ME" --state open --limit 60 \
             --json number,mergeStateStatus,statusCheckRollup \
             -q '[.[]|{number,mergeStateStatus,checks:[(.statusCheckRollup//[])[]|{name:(.name//.context),conclusion}]}]' \
             2>/dev/null || echo '[]')"
    _mf="$(gh api "repos/$ME/chump/commits/main/check-runs" \
             -q '[.check_runs[]|{name:.name,conclusion:.conclusion}]' 2>/dev/null || echo '[]')"
    _cls="$(classify_pile "$_pf" "$_mf")"
    genuine="$(echo "$_cls" | sed -n '1p' | awk '{print $1}')"
    systemic="$(echo "$_cls" | sed -n '1p' | awk '{print $2}')"
    systemic_prs="$(echo "$_cls" | sed -n '2p')"
    genuine="${genuine:-0}"; systemic="${systemic:-0}"
    raw_pile=$(( genuine + systemic ))
fi
# `pile` = GENUINE jam depth. Every halt/resume/escape decision below keys on it,
# so systemic-red victims can never, by themselves, halt or hold the line.
pile="$genuine"
if [[ -n "${CHUMP_BACKPRESSURE_RUNNING:-}" ]]; then
    running="$CHUMP_BACKPRESSURE_RUNNING"
else
    running="$(systemctl list-units 2>/dev/null | grep -c 'chump-worker@[0-9].*running')"
fi
auton="$(cat "$AUTON" 2>/dev/null || echo 5)"
halted=0; { (( running == 0 )) || [[ "$auton" == "0" ]]; } && halted=1

echo "[back-pressure $(ts)] genuine-jam=$pile systemic-red=$systemic raw-pile=${raw_pile:-$pile} (halt>=$HALT_AT resume<=$RESUME_AT) workers=$running autonomy=$auton halted=$halted"

# ── RESILIENT-308: systemic-red victims → signal + rerun, never halt on them ──
# Fire every tick that any exist (cooldown-guarded downstream), BEFORE the halt
# check, so the flaky/shared red gets rerun toward green and never accumulates
# into a spurious jam. `pile` (=genuine) already excludes them, so the halt logic
# below cannot trip on these PRs.
if (( systemic > 0 )); then
    trigger_systemic_rerun "$systemic" "$systemic_prs"
fi

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
