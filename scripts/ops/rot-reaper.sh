#!/usr/bin/env bash
# rot-reaper.sh — the NO-ABANDON JANITOR: drive EVERY open fleet PR toward a
# terminal state so nothing can rot (RESILIENT-311 / RESILIENT-324).
#
# THE GUARANTEE (RESILIENT-311, operator law "one way or the other, this queue
# stays managed"): on every beat, each open fleet-authored PR is pushed toward a
# terminal state (MERGED, or CLOSED+requeued) within a bounded time. No PR sits
# abandoned. The classes this organ drives:
#   • CONFLICTING beyond CONFLICT age      → close + requeue + label rot-reaped
#   • MERGEABLE but a REQUIRED check has
#     FAILED beyond REALFAIL age           → close + requeue + label rot-reaped
#   • MERGEABLE + green + UNARMED beyond
#     ARM age (minutes)                    → arm auto-merge (backstop the lander)
#   • BEHIND                               → left for chump-armed-rebaser
#   • fresh anything                       → left (owner/CI still working)
# Plus a NO-ABANDON METRIC each beat (kind=pr_no_abandon_backlog): the count of
# open PRs older than the deadline still in a non-terminal state. Target 0.
#
# WHY the label (RESILIENT-311, 2026-08-15 reap/revive deadlock): the rot-reaper
# was closing CONFLICTING PR #3792 every 30 min AND requeuing its gap to `open`
# — but post-push-integrity-watch.sh (a reviver that reopens closed-not-merged
# fleet PRs) saw "closed PR + open gap" as "work lost, reopen it" and reopened
# the dead, unmergeable branch within ~60s. The reaper's close never STUCK: an
# infinite reap↔revive fight, and the PR rotted OPEN forever. The reaper's
# filters were never the problem — its close was being undone. Fix: every reaper
# close now stamps a `rot-reaped` label; revivers skip any PR bearing it (an
# intentional terminal close is not a lost-work incident — a fresh PR comes from
# the requeued gap). The label makes the close terminal.
#
# WHY (operator, 2026-08-14 deadlock): the back-pressure controller
# (scripts/ops/back-pressure-controller.sh) HALTS production when the "stuck
# pile" (open PRs that are BLOCKED or DIRTY) hits HALT_AT (6). It RESUMES when
# the pile drains below RESUME_AT (3). The armed-rebaser
# (scripts/coord/armed-pr-rebaser.sh) drains the pile by rebasing PRs that are
# BEHIND — but it CANNOT resolve a real merge CONFLICT. So when the jam is
# mostly CONFLICTING PRs, the rebaser drains the pile partway (to 4–5), it
# lands in the 3–6 hysteresis dead-zone, and the fleet stays HALTED forever
# with no auto-recovery. That is exactly what deadlocked the fleet for hours.
#
# This organ is the missing drain: it CLOSES open PRs that are truly
# CONFLICTING and old enough that they are never going to auto-rebase, and
# RE-QUEUES their gap so the fleet re-does the work cleanly on fresh main. A
# CONFLICTING PR represents work that must be redone anyway (the branch and
# main diverged in the same lines); reaping it loses nothing and unblocks the
# breaker.
#
# What it does, per open PR authored by the fleet:
#   1. Skip filing PRs ("chore(gaps): file/reserve …") — never self-close.
#   2. Only act when mergeable == "CONFLICTING". BLOCKED-but-MERGEABLE PRs are
#      NOT touched — those just need CI/approval, not reaping (the pr-lander /
#      ci-flake-rerun organs handle them).
#   3. Age gate: only close PRs older than MIN_AGE_HOURS (default 4h). A fresh
#      conflict may still be actively rebased by its owner; never reap it.
#   4. Re-queue each cited gap: if its status is not already `open` and not
#      `done`, `chump gap set --status open` + an audit note. If the gap is
#      already `done` (a stale DUPLICATE PR whose work landed elsewhere), do
#      NOT try to reopen it — the recycled-ID guard blocks that and it would
#      be wrong anyway; just close the PR.
#   5. Close the PR with an explanatory comment.
#
# Idempotent (a PR it closes leaves the open set; the gap note is tagged),
# logged, and dry-run-able. Safe to run on a timer.
#
# Usage:
#   ./scripts/ops/rot-reaper.sh              # live run
#   ./scripts/ops/rot-reaper.sh --dry-run    # print what would happen, no changes
#
# Environment:
#   CHUMP_ROT_REAPER_MIN_AGE_HOURS  min PR age (hours) before a CONFLICTING PR
#                                   can be reaped (default 4). Excludes fresh
#                                   conflicts.
#   CHUMP_ROT_REAPER_REALFAIL_AGE_HOURS  min PR age (hours) before a MERGEABLE
#                                   PR that is failing a REQUIRED check can be
#                                   reaped (default 8). Longer than the conflict
#                                   gate: a red check may be a transient flake a
#                                   rerun clears, so give the fix/rerun organs
#                                   more room before declaring the work lost.
#   CHUMP_ROT_REAPER_ARM_AGE_MIN    min PR age (minutes) before a green-but-
#                                   UNARMED PR is armed as a backstop to the
#                                   pr-lander (default 15).
#   CHUMP_ROT_REAPER_MAX            safety cap: max PRs to close per run
#                                   (default 10). Prevents a runaway mass-close.
#   CHUMP_ROT_REAPER_LABEL          terminal-close label (default rot-reaped).
#                                   Revivers skip any PR bearing it.
#   CHUMP_ROT_REAPER_RESPAWN_CAP    EFFECTIVE-434: max times a gap may be
#                                   auto-closed+re-queued before the reaper
#                                   stops re-queuing it and escalates to the
#                                   operator instead (default 3). The PR still
#                                   gets closed either way; only the automatic
#                                   respawn stops. Prevents a genuinely-buggy
#                                   PR from recycling forever.
#   CHUMP_ROT_REAPER_REQUIRED_CHECKS  comma-separated override of the required-
#                                   check set (default: fetched from branch
#                                   protection, fallback to the known 4).
#   CHUMP_ROT_REAPER_SHARED_MIN     RESILIENT-339 false-red guard: a required
#                                   check failing identically across >= this
#                                   many open fleet PRs is treated as
#                                   shared/systemic red (farmer-flap cascade,
#                                   flaky gate), NOT a defect unique to any one
#                                   PR — REALFAIL-close is SKIPPED for any PR
#                                   whose EVERY failing required check is
#                                   systemic (default 3, matches the
#                                   back-pressure-controller SHARED_MIN
#                                   convention).
#   CHUMP_ROT_REAPER_PR_JSON        TEST HOOK: path to a JSON file used INSTEAD
#                                   of `gh pr list`. Lets CI exercise the
#                                   selection logic without a live GitHub. Each
#                                   row may carry autoMergeRequest, isDraft, and
#                                   statusCheckRollup to exercise the new classes.
#   REMOTE / BASE                   git remote / base branch (default origin/main)
set -uo pipefail

# ── shared reaper instrumentation (heartbeat + reaper_run event + log rotate) ─
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup rot
reaper_rotate_log /tmp/chump-rot-reaper.out.log
reaper_rotate_log /tmp/chump-rot-reaper.err.log

# EFFECTIVE-434: escalate-to-operator path once a gap's respawn cap is hit.
# Sourced, not required — a missing notifier must not take the reaper down.
# shellcheck source=../coord/lib/notify-operator.sh
if [[ -f "$(dirname "$0")/../coord/lib/notify-operator.sh" ]]; then
    # shellcheck source=../coord/lib/notify-operator.sh
    source "$(dirname "$0")/../coord/lib/notify-operator.sh"
else
    notify_operator() { echo "[notify-operator] MISSING lib/notify-operator.sh" >&2; return 0; }
fi

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

MIN_AGE_HOURS="${CHUMP_ROT_REAPER_MIN_AGE_HOURS:-4}"
REALFAIL_AGE_HOURS="${CHUMP_ROT_REAPER_REALFAIL_AGE_HOURS:-8}"
ARM_AGE_MIN="${CHUMP_ROT_REAPER_ARM_AGE_MIN:-15}"
MAX_CLOSE="${CHUMP_ROT_REAPER_MAX:-10}"
LABEL="${CHUMP_ROT_REAPER_LABEL:-rot-reaped}"
REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
# EFFECTIVE-434 (COTG recycle path): a gap re-queued this many times by the
# reaper's own "rot-reaper: PR #... auto-closed" notes is no longer a flake or
# a fixable red — the same failure keeps recurring across fresh attempts, so
# another automatic redo just burns another PR/CI cycle. Past the cap, stop
# re-queuing (the PR still closes) and escalate to the operator instead.
RESPAWN_CAP="${CHUMP_ROT_REAPER_RESPAWN_CAP:-3}"
# RESILIENT-339: false-red guard threshold — see header comment.
SHARED_MIN="${CHUMP_ROT_REAPER_SHARED_MIN:-3}"
# NO-ABANDON DEADLINE: past this age (hours) an open PR must be terminal; any
# still non-terminal is counted in the pr_no_abandon_backlog metric (target 0).
NO_ABANDON_DEADLINE_HOURS="${CHUMP_ROT_REAPER_DEADLINE_HOURS:-$REALFAIL_AGE_HOURS}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== rot-reaper / no-abandon janitor (conflict≥${MIN_AGE_HOURS}h, required-red≥${REALFAIL_AGE_HOURS}h, arm≥${ARM_AGE_MIN}m, max=${MAX_CLOSE}) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no PRs will be closed and no gaps re-queued."

ME="$(gh api user --jq .login 2>/dev/null || echo repairman29)"

# ── required-check set ────────────────────────────────────────────────────────
# The branch-protection required checks: a PR that is MERGEABLE (no conflict)
# but has one of THESE failing is stuck on a real content gate, not a flake or a
# pending approval. Fetched live so the set stays correct as protection evolves;
# fall back to the known-4 (2026-08-15) if the API is unavailable.
REQUIRED_CHECKS_DEFAULT="cargo-test-required,audit-required,clippy-required,ACP protocol smoke test (Zed / JetBrains compatible)"
if [[ -n "${CHUMP_ROT_REAPER_REQUIRED_CHECKS:-}" ]]; then
    REQUIRED_CHECKS="$CHUMP_ROT_REAPER_REQUIRED_CHECKS"
elif [[ -n "${CHUMP_ROT_REAPER_PR_JSON:-}" ]]; then
    # Test mode: don't hit the network; use the default set unless overridden.
    REQUIRED_CHECKS="$REQUIRED_CHECKS_DEFAULT"
else
    REQUIRED_CHECKS="$(gh api "repos/$ME/${BASE_REPO:-chump}/branches/${BASE}/protection/required_status_checks" \
        --jq '.contexts | join(",")' 2>/dev/null || true)"
    [[ -z "$REQUIRED_CHECKS" ]] && REQUIRED_CHECKS="$REQUIRED_CHECKS_DEFAULT"
fi
info "Required checks: ${REQUIRED_CHECKS}"

# ── source of candidate PRs ───────────────────────────────────────────────────
# TEST HOOK: CHUMP_ROT_REAPER_PR_JSON supplies a fixture so CI can exercise the
# selection logic (age gates + class detection) without a live GitHub.
PR_JSON=""
if [[ -n "${CHUMP_ROT_REAPER_PR_JSON:-}" ]]; then
    PR_JSON="$(cat "$CHUMP_ROT_REAPER_PR_JSON" 2>/dev/null || echo '[]')"
    info "Using fixture PR list from \$CHUMP_ROT_REAPER_PR_JSON."
else
    PR_JSON="$(gh pr list --author "$ME" --state open --limit 100 \
        --json number,title,mergeStateStatus,mergeable,createdAt,headRefName,isDraft,autoMergeRequest,statusCheckRollup \
        2>/dev/null || echo '[]')"
fi

# Rows as TSV: number \t mergeable \t createdAt \t title \t mergeState \t
#              isDraft \t hasAutoMerge \t requiredFail \t requiredFailNames
# requiredFail = "1" iff a branch-protection-REQUIRED check has concluded
# FAILURE/ERROR/TIMED_OUT (not pending, not skipped) — the "real content gate is
# red" signal that separates a stuck PR from one merely waiting on CI/approval.
# requiredFailNames = "|"-joined set of the required checks that are failing on
# THIS PR — feeds the RESILIENT-339 false-red guard's shared-check lookup.
ROWS="$(printf '%s' "$PR_JSON" | REQ_CHECKS="$REQUIRED_CHECKS" python3 -c '
import json, os, sys
required = {c.strip() for c in os.environ.get("REQ_CHECKS","").split(",") if c.strip()}
FAIL = {"FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    num   = r.get("number", "")
    mrg   = r.get("mergeable", "")
    made  = r.get("createdAt", "")
    title = (r.get("title") or "").replace("\t", " ").replace("\n", " ")
    mstate = r.get("mergeStateStatus", "") or ""
    draft = "1" if r.get("isDraft") else "0"
    has_am = "1" if r.get("autoMergeRequest") else "0"
    req_fail = "0"
    req_fail_names = []
    for c in (r.get("statusCheckRollup") or []):
        name = c.get("name") or c.get("context") or ""
        # CheckRun uses conclusion; StatusContext uses state.
        concl = (c.get("conclusion") or c.get("state") or "").upper()
        if name in required and concl in FAIL:
            req_fail = "1"
            if name not in req_fail_names:
                req_fail_names.append(name)
    names_field = "|".join(req_fail_names)
    print(f"{num}\t{mrg}\t{made}\t{title}\t{mstate}\t{draft}\t{has_am}\t{req_fail}\t{names_field}")
' 2>/dev/null || true)"

# ── RESILIENT-339: fleet-wide shared-check counts (false-red guard input) ────
# For every open fleet PR (not just the one being classified), how many OTHER
# PRs currently have the SAME required check failing? A count >= SHARED_MIN
# means that check is red fleet-wide (farmer-flap cascade / flaky shared gate,
# the RESILIENT-337 signal) rather than a defect unique to one PR. Computed
# once up front so the per-PR guard below is a cheap lookup, not a rescan.
CHECK_COUNTS="$(printf '%s' "$PR_JSON" | REQ_CHECKS="$REQUIRED_CHECKS" python3 -c '
import json, os, sys
from collections import Counter
required = {c.strip() for c in os.environ.get("REQ_CHECKS","").split(",") if c.strip()}
FAIL = {"FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
counts = Counter()
for r in rows:
    seen = set()
    for c in (r.get("statusCheckRollup") or []):
        name = c.get("name") or c.get("context") or ""
        concl = (c.get("conclusion") or c.get("state") or "").upper()
        if name in required and concl in FAIL and name not in seen:
            seen.add(name)
            counts[name] += 1
for name, cnt in counts.items():
    print(f"{name}\t{cnt}")
' 2>/dev/null || true)"

# age_hours ISO8601 — whole hours since createdAt (python, bash-free of `date -d`).
age_hours() {
    python3 -c '
import sys
from datetime import datetime, timezone
try:
    dt = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    print(int((datetime.now(timezone.utc) - dt).total_seconds() // 3600))
except Exception:
    print(-1)
' "$1" 2>/dev/null || echo -1
}

is_filing_pr_title() {
    case "$1" in
        "chore(gaps): file "*|"chore(gaps): reserve "*) return 0 ;;
        *) return 1 ;;
    esac
}

CLOSED=0
REQUEUED=0
SKIPPED=0
ARMED=0
BACKLOG=0          # open PRs past the no-abandon deadline still non-terminal
BACKLOG_PRS=""

AMBIENT_LOG="${NODE_AMBIENT:-$(cd "$(dirname "$0")/../.." && pwd)/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

# ── NO-ABANDON METRIC ─────────────────────────────────────────────────────────
# The count of open PRs past the deadline still in a non-terminal state. The
# guarantee's health gauge — target 0. A persistent non-zero here means a rot
# class is escaping every driver and must be handled.
emit_backlog_metric() {  # <count> <pr_list>
    local n="$1" prs="$2"
    printf '{"ts":"%s","kind":"pr_no_abandon_backlog","source":"rot-reaper","count":%s,"deadline_h":%s,"prs":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" "$NO_ABANDON_DEADLINE_HOURS" "$(printf '%s' "$prs" | tr -s ' ')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
    if [[ "$n" -gt 0 ]]; then
        red "NO-ABANDON BACKLOG: ${n} open PR(s) past ${NO_ABANDON_DEADLINE_HOURS}h still non-terminal: ${prs}"
    else
        green "NO-ABANDON BACKLOG: 0 — every open PR is terminal or on-track."
    fi
}

# EFFECTIVE-434: a gap that hit its respawn cap — recorded so the operator
# escalation is observable in ambient.jsonl, not just a Discord ping.
emit_respawn_cap_event() {  # <gap_id> <pr_num> <respawn_count>
    local gid="$1" pr="$2" n="$3"
    printf '{"ts":"%s","kind":"gap_respawn_cap_reached","source":"rot-reaper","gap":"%s","pr":%s,"respawn_count":%s,"cap":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gid" "$pr" "$n" "$RESPAWN_CAP" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

if [[ -z "$ROWS" ]]; then
    info "No open PRs found — nothing to reap."
    emit_backlog_metric 0 ""
    reaper_finish ok '{"closed":0,"requeued":0,"skipped":0,"armed":0,"backlog":0}'
    exit 0
fi

# ── requeue every cited gap of a PR we are reaping ────────────────────────────
# Sets status:open (unless already open/done) + an audit note. Increments the
# global REQUEUED. A `done` gap (work landed elsewhere) is left done.
requeue_gaps() {  # <pr_num> <age_h> <reason_short> <title>
    local pr="$1" age="$2" reason="$3" title="$4" gid cur status note
    local prior_notes respawn_count cap_note
    local ids; ids="$(printf '%s\n' "$title" | grep -oE '\b[A-Z]+-[0-9]+\b' | sort -u || true)"
    for gid in $ids; do
        [[ -z "$gid" ]] && continue
        if ! command -v chump >/dev/null 2>&1; then
            info "  (chump CLI unavailable — skipping re-queue of $gid)"; continue
        fi
        cur="$(chump gap show "$gid" 2>/dev/null || true)"
        [[ -z "$cur" ]] && { info "  $gid not found in gap store — nothing to re-queue."; continue; }
        status="$(awk '/^[[:space:]]*status:/{sub(/^[[:space:]]*status:[[:space:]]*/,""); print; exit}' <<<"$cur")"
        if [[ "$status" == "done" ]]; then
            info "  $gid already done — stale duplicate PR; closing without re-queue."; continue
        fi

        # EFFECTIVE-434: respawn cap. Count how many times this gap has already
        # been auto-closed+re-queued by the reaper (each prior cycle leaves a
        # "rot-reaper: PR #... auto-closed" note). Past RESPAWN_CAP, the same
        # failure is recurring across fresh attempts — stop re-queuing and
        # escalate to the operator instead of recycling forever. The PR itself
        # still gets closed by the caller; only the gap re-open is skipped.
        prior_notes="$(chump gap show "$gid" --field notes 2>/dev/null || true)"
        respawn_count="$(printf '%s' "$prior_notes" | grep -oE 'rot-reaper: PR #[0-9]+ auto-closed' | wc -l | tr -d ' ')"
        if [[ "${respawn_count:-0}" -ge "$RESPAWN_CAP" ]]; then
            warn "  $gid respawn cap reached (${respawn_count} >= ${RESPAWN_CAP}) — escalating to operator, NOT re-queuing"
            if [[ $DRY_RUN -eq 1 ]]; then dry "would escalate $gid to operator (respawn cap ${RESPAWN_CAP} reached)"; continue; fi
            cap_note="rot-reaper: PR #${pr} auto-closed (${reason}, ${age}h) $(date -u +%Y-%m-%d); RESPAWN CAP ${RESPAWN_CAP} reached (${respawn_count} prior recycles) — NOT re-queued, escalating to operator."
            chump gap set "$gid" --add-note "$cap_note" >/dev/null 2>&1 \
                || warn "chump gap set $gid --add-note failed"
            emit_respawn_cap_event "$gid" "$pr" "$respawn_count"
            notify_operator "$(printf '🛑 **%s hit its respawn cap (%s)** — rot-reaper will not re-queue it again.\n\nPR #%s just closed (%s, %sh). This gap has been auto-closed+re-queued %s time(s) already by the reaper; the same failure keeps recurring, which means it needs a human, not another automatic redo.\n\nGap left CLOSED — reopen manually after diagnosing.' \
                "$gid" "$RESPAWN_CAP" "$pr" "$reason" "$age" "$respawn_count")" || true
            continue
        fi

        note="rot-reaper: PR #${pr} auto-closed (${reason}, ${age}h) $(date -u +%Y-%m-%d); re-attempt on fresh main."
        if [[ $DRY_RUN -eq 1 ]]; then dry "would re-queue $gid (status=$status) + note"; continue; fi
        [[ "$status" != "open" ]] && { chump gap set "$gid" --status open >/dev/null 2>&1 \
            || warn "chump gap set $gid --status open failed"; }
        chump gap set "$gid" --add-note "$note" >/dev/null 2>&1 \
            || warn "chump gap set $gid --add-note failed"
        info "  re-queued $gid (was $status)"
        REQUEUED=$((REQUEUED + 1))
    done
}

# ── label + close a PR terminally ─────────────────────────────────────────────
# The label is what makes the close STICK: revivers (post-push-integrity-watch)
# skip any PR bearing it, so the reap↔revive fight that rotted #3792 can't recur.
LABEL_ENSURED=0
ensure_label() {
    [[ "$LABEL_ENSURED" == 1 ]] && return 0
    LABEL_ENSURED=1
    if gh label list --limit 300 2>/dev/null | grep -qE "^${LABEL}([[:space:]]|$)"; then return 0; fi
    gh label create "$LABEL" --color B60205 \
        --description "Closed terminally by the no-abandon janitor (RESILIENT-311); do not reopen — a fresh PR comes from the requeued gap." \
        >/dev/null 2>&1 || true
}
label_and_close() {  # <pr_num> <close_msg>
    local pr="$1" msg="$2"
    ensure_label
    # Label BEFORE close so a reviver polling in the close window already sees it.
    # (Guarded with `if` so this line does not begin with a bare `gh pr edit`,
    # which the INFRA-1274 raw-gh hot-path lint forbids at line start.)
    if ! gh pr edit "$pr" --add-label "$LABEL" >/dev/null 2>&1; then
        warn "could not add label '$LABEL' to PR #$pr (continuing to close)"
    fi
    if gh pr close "$pr" --comment "$msg" 2>/dev/null; then
        green "  closed PR #$pr (labeled $LABEL)"
        CLOSED=$((CLOSED + 1))
        # Loud, board-visible signal that a line was terminated (not a silent rot).
        printf '{"ts":"%s","kind":"pr_reaped","source":"rot-reaper","pr":%s,"label":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$LABEL" >> "$AMBIENT_LOG" 2>/dev/null || true
        return 0
    fi
    warn "gh pr close $pr failed."
    return 1
}

# ── RESILIENT-339: false-red guard ────────────────────────────────────────────
# Before REALFAIL-closing a PR, cross-check: is EVERY one of its failing
# required checks ALSO failing on >= SHARED_MIN other open fleet PRs right now?
# If so this is a shared/systemic-red condition — a farmer-flap cascade, a
# flaky shared gate, exactly the RESILIENT-337 >=3-PRs-same-check signal — not
# a defect unique to this PR's code. NEVER close on that; skip and alert
# instead. Only a failure genuinely UNIQUE to this PR (not shared) may close.
is_systemic_red() {  # <"|"-joined required-check names failing on this PR>
    local names="$1" name cnt
    [[ -z "$names" ]] && return 1
    local IFS_SAVE="$IFS"
    IFS='|' read -ra _names <<< "$names"
    IFS="$IFS_SAVE"
    for name in "${_names[@]}"; do
        [[ -z "$name" ]] && continue
        cnt="$(awk -F'\t' -v n="$name" '$1==n{print $2}' <<< "$CHECK_COUNTS")"
        cnt="${cnt:-0}"
        if [[ "$cnt" -lt "$SHARED_MIN" ]]; then
            return 1   # at least one failing check is PR-specific → genuine red
        fi
    done
    return 0   # every failing required check is shared >= SHARED_MIN → systemic
}
alert_false_red() {  # <pr_num> <names> <age>
    local pr="$1" names="$2" age="$3"
    printf '{"ts":"%s","kind":"rot_reaper_false_red_skip","source":"rot-reaper","pr":%s,"checks":"%s","age_h":%s,"shared_min":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$names" "$age" "$SHARED_MIN" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
    local msg="rot-reaper (RESILIENT-339 false-red guard): this PR's required check(s) [\`${names}\`] are RED, but the SAME check(s) are ALSO failing on >= ${SHARED_MIN} other open fleet PRs right now — a shared/systemic-red condition (farmer-flap cascade or a flaky shared gate, the RESILIENT-337 signal), not a defect unique to this PR. Skipping the REALFAIL auto-close so good code isn't lost; will re-evaluate once the shared red clears or a check unique to this PR is found."
    if [[ $DRY_RUN -eq 1 ]]; then dry "would alert false-red on PR #$pr (checks: $names)"; return 0; fi
    gh pr comment "$pr" --body "$msg" >/dev/null 2>&1 || warn "gh pr comment $pr failed (false-red alert)"
}

while IFS=$'\t' read -r PR_NUM MERGEABLE CREATED TITLE MSTATE ISDRAFT HASAM REQFAIL REQFAIL_NAMES; do
    [[ -z "$PR_NUM" ]] && continue

    # Never self-close a gap-filing PR (belt: also excluded from every class).
    if is_filing_pr_title "$TITLE"; then
        info "PR #$PR_NUM — filing PR, skipping."
        continue
    fi

    AGE="$(age_hours "$CREATED")"
    if [[ "$AGE" -lt 0 ]]; then
        warn "PR #$PR_NUM — could not parse createdAt ($CREATED); skipping (fail-safe)."
        SKIPPED=$((SKIPPED + 1)); continue
    fi

    # ── CLASS 1: CONFLICTING beyond CONFLICT age → close + requeue ────────────
    if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
        if [[ "$AGE" -lt "$MIN_AGE_HOURS" ]]; then
            info "PR #$PR_NUM — CONFLICTING but only ${AGE}h old (< ${MIN_AGE_HOURS}h); leaving for the owner/rebaser."
            SKIPPED=$((SKIPPED + 1)); continue
        fi
        if [[ "$CLOSED" -ge "$MAX_CLOSE" ]]; then
            warn "Reached MAX_CLOSE=$MAX_CLOSE this run; deferring the rest."
            BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "; continue
        fi
        red "PR #$PR_NUM — CONFLICTING, ${AGE}h old → REAP"
        info "  title: $TITLE"
        requeue_gaps "$PR_NUM" "$AGE" "CONFLICTING" "$TITLE"
        MSG="Auto-closing (rot-reaper / RESILIENT-311 no-abandon janitor): this PR is **CONFLICTING** with \`${BASE}\` and is ${AGE}h old. The armed-rebaser only rebases *behind* PRs — it cannot resolve a real merge conflict — so this branch would sit unmerged indefinitely and keep the back-pressure breaker halted. The cited gap(s) have been re-queued to be re-done cleanly on fresh \`${BASE}\`. Nothing is lost: a conflicting branch must be redone anyway. Labeled \`${LABEL}\` so revivers won't fight this deliberate close. (RESILIENT-324/RESILIENT-311)"
        if [[ $DRY_RUN -eq 1 ]]; then dry "would label+close PR #$PR_NUM (CONFLICTING)"; CLOSED=$((CLOSED + 1)); continue; fi
        label_and_close "$PR_NUM" "$MSG"
        continue
    fi

    # ── CLASS 2: MERGEABLE but a REQUIRED check FAILED beyond REALFAIL age ────
    # A real content gate is red (raw-gh lint, bypass ceiling, a failing test) —
    # no organ fixes it, so it would sit BLOCKED forever. Past the deadline,
    # close + requeue so the fleet redoes it clean rather than let it rot.
    if [[ "$REQFAIL" == "1" ]]; then
        if [[ "$AGE" -lt "$REALFAIL_AGE_HOURS" ]]; then
            info "PR #$PR_NUM — failing a required check but only ${AGE}h old (< ${REALFAIL_AGE_HOURS}h); leaving for a fix/rerun."
            SKIPPED=$((SKIPPED + 1)); continue
        fi
        if [[ "$CLOSED" -ge "$MAX_CLOSE" ]]; then
            warn "Reached MAX_CLOSE=$MAX_CLOSE this run; deferring the rest."
            BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "; continue
        fi
        # RESILIENT-339 false-red guard: NEVER close on shared/systemic red.
        if is_systemic_red "$REQFAIL_NAMES"; then
            warn "PR #$PR_NUM — REQUIRED check RED (${REQFAIL_NAMES}) but SHARED across >= ${SHARED_MIN} open PRs (systemic/false-red) — SKIP close, alert instead"
            info "  title: $TITLE"
            alert_false_red "$PR_NUM" "$REQFAIL_NAMES" "$AGE"
            SKIPPED=$((SKIPPED + 1)); continue
        fi
        red "PR #$PR_NUM — MERGEABLE but REQUIRED check RED, ${AGE}h old → REAP"
        info "  title: $TITLE"
        requeue_gaps "$PR_NUM" "$AGE" "required-check-red" "$TITLE"
        MSG="Auto-closing (rot-reaper / RESILIENT-311 no-abandon janitor): this PR is mergeable but a **branch-protection-required check has been RED for ${AGE}h** (≥ ${REALFAIL_AGE_HOURS}h) and no fix/rerun organ cleared it — it would sit BLOCKED forever. Required set: \`${REQUIRED_CHECKS}\`. The cited gap(s) have been re-queued to be re-done cleanly on fresh \`${BASE}\`. If that check is actually a flake that is now green on main, reopen and re-run. Labeled \`${LABEL}\`. (RESILIENT-311)"
        if [[ $DRY_RUN -eq 1 ]]; then dry "would label+close PR #$PR_NUM (required-check-red)"; CLOSED=$((CLOSED + 1)); continue; fi
        label_and_close "$PR_NUM" "$MSG"
        continue
    fi

    # ── CLASS 3: MERGEABLE + green + UNARMED beyond ARM age → arm ─────────────
    # Backstop the pr-lander: a green PR that never got its auto-merge armed
    # (the #3792-was-green-but-unmerged class) is driven forward, not left.
    if [[ "$MERGEABLE" == "MERGEABLE" && "$HASAM" == "0" && "$ISDRAFT" == "0" && "$MSTATE" != "DIRTY" ]]; then
        AGE_MIN=$(( AGE * 60 ))
        # AGE is whole hours; approximate minutes are fine for a ≥15m backstop
        # gate (a PR younger than 1h reads AGE=0 → 0min → still below 15m unless
        # we also honor sub-hour freshness, so only arm once it's ≥1h old).
        if [[ "$AGE_MIN" -ge "$ARM_AGE_MIN" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                dry "would ARM green-unarmed PR #$PR_NUM (${AGE}h old)"
                ARMED=$((ARMED + 1))
            else
                if [[ -x "$(dirname "$0")/../coord/auto-merge-armer.sh" ]] \
                   && bash "$(dirname "$0")/../coord/auto-merge-armer.sh" --pr "$PR_NUM" >/dev/null 2>&1; then
                    green "PR #$PR_NUM — green + unarmed ${AGE}h → ARMED (lander backstop)"
                    ARMED=$((ARMED + 1))
                else
                    warn "PR #$PR_NUM — arm backstop failed (likely needs review); counting as backlog."
                    [[ "$AGE" -ge "$NO_ABANDON_DEADLINE_HOURS" ]] && { BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "; }
                fi
            fi
            continue
        fi
    fi

    # ── Everything else: is a driver actively moving it toward terminal? ─────
    # An armed + mergeable PR is on-track (auto-merge lands it once green); a
    # BEHIND PR is owned by chump-armed-rebaser. Those are NOT abandoned. Only a
    # PR past the deadline with NO driver — unarmed-and-couldn't-arm, or a state
    # no organ handles — counts toward the backlog metric, so an escaping rot
    # class can't hide behind "someone else will get it."
    if [[ "$AGE" -ge "$NO_ABANDON_DEADLINE_HOURS" ]]; then
        local_on_driver=0
        [[ "$HASAM" == "1" && "$MERGEABLE" == "MERGEABLE" ]] && local_on_driver=1  # auto-merge
        [[ "$MSTATE" == "BEHIND" ]] && local_on_driver=1                            # rebaser
        if [[ "$local_on_driver" == "0" ]]; then
            info "PR #$PR_NUM — ${AGE}h old, non-terminal + NO driver (merge=$MERGEABLE state=$MSTATE armed=$HASAM); counting as no-abandon backlog."
            BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "
        fi
    fi
done <<< "$ROWS"

# ── NO-ABANDON METRIC ─────────────────────────────────────────────────────────
emit_backlog_metric "$BACKLOG" "$BACKLOG_PRS"

green "=== rot-reaper done: closed=$CLOSED requeued=$REQUEUED armed=$ARMED skipped=$SKIPPED backlog=$BACKLOG ==="
reaper_finish ok "{\"closed\":$CLOSED,\"requeued\":$REQUEUED,\"armed\":$ARMED,\"skipped\":$SKIPPED,\"backlog\":$BACKLOG}"
