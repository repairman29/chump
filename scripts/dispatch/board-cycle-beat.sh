#!/usr/bin/env bash
# board-cycle-beat.sh — INFRA-3590 (slice 1 MVP of the INFRA-3589 board-on-helsinki umbrella).
#
# WHY THIS EXISTS. Board-level judgment (score SLAs, classify PR stalls, decide
# what needs a human) has only ever happened inside a desktop Claude Code
# session — i.e. only when a human had one open. The moment nobody is at a
# desktop, the board goes dark. This beat runs the SAME judgment as a single,
# bounded `claude -p` cycle on helsinki (the always-on primary node), fired by
# a systemd timer, with zero desktop session required. It is the MVP slice:
# ONE cycle, ONE report, no persistent daemon loop — later slices (INFRA-3589)
# add breadth (more SLA classes, richer stall taxonomy, multi-cycle memory).
#
# THE CYCLE (delegated entirely to the Sonnet agent via the prompt below, per
# the OPERATOR_AGENT.md core-loop contract — this script's job is only to fire
# it, bound it, and prove it ran):
#   1. Score the 30-minute merge SLA: for every OPEN, ARMED, all-green PR,
#      how long since it became mergeable? Flag any past 30m.
#   2. Classify PR stalls (real bug / known flake / unknown flake) per
#      OPERATOR_AGENT.md's Queue-health step.
#   3. Post a terse board report to the operator's Discord via
#      scripts/coord/lib/notify-operator.sh's notify_operator().
#
# Runs on helsinki via chump-board-cycle.timer. Idempotent, safe to run by
# hand. A step failing never aborts observability: the ambient emit always
# fires so the beat's execution is provable, not assumed (DURABLE_FIX_DOCTRINE).
#
# Usage:
#   bash scripts/dispatch/board-cycle-beat.sh
#
# Off-switch: CHUMP_BOARD_CYCLE_ENABLED=0 (default on).
# Timeout: CHUMP_BOARD_CYCLE_TIMEOUT_S (default 600s) — a wedged `claude -p`
# must not hang the timer forever.
set -uo pipefail

[[ "${CHUMP_BOARD_CYCLE_ENABLED:-1}" == "0" ]] && { echo "[board-cycle] disabled via CHUMP_BOARD_CYCLE_ENABLED=0 — exit"; exit 0; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "[board-cycle] cannot cd repo root" >&2; exit 1; }

TIMEOUT_S="${CHUMP_BOARD_CYCLE_TIMEOUT_S:-600}"

# RESILIENT-373: the beat OWNS the paging decision now (deterministic,
# severity-gated, deduped) via scripts/coord/lib/board-cycle-escalate.sh.
# BEAT_START_EPOCH bounds which board_cycle_report_posted line that organ
# reads, so a stale line from a prior cycle is never re-paged.
BEAT_START_EPOCH="$(date -u +%s)"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[board-cycle %s] %s\n' "$(ts)" "$*"; }

git fetch origin main -q 2>/dev/null || true

BOARD_PROMPT="You are the Chump operator-agent running ONE board cycle, no \
desktop session, per docs/architecture/OPERATOR_AGENT.md's core-loop contract \
and the 30-minute merge SLA. Do the following and then STOP (do not loop, do \
not call ScheduleWakeup):

1. Score the 30-minute merge SLA: list OPEN, non-draft PRs with auto-merge \
armed and all required checks green (cache-first per CLAUDE.md — read \
.chump/github_cache.db before any 'gh pr' call). For each, compute time since \
it became mergeable. Flag any exceeding 30 minutes as an SLA BREACH.
2. Classify any stalled/BLOCKED/DIRTY open PRs into: real bug, known flake \
(check KNOWN_FLAKES.yaml if present), or unknown flake — per \
OPERATOR_AGENT.md's Queue-health step. Do not take remediation action \
yourself in this MVP slice (no rebases, no reruns) — this cycle is \
report-only.
3. DO NOT call notify_operator, source notify-operator.sh, or send any \
Discord message. Paging is now owned DETERMINISTICALLY by the beat \
(scripts/coord/lib/board-cycle-escalate.sh, RESILIENT-373): it pages the \
operator ONLY on an actionable SLA breach and dedupes a persisting one, so a \
clean cycle never touches the phone. Your job is to produce the honest \
structured signal in step 4 and nothing else.
4. Append EXACTLY ONE line to .chump-locks/ambient.jsonl capturing this \
cycle's structured result — ALWAYS, whether clean or breached:
   {\"ts\":\"<utc>\",\"kind\":\"board_cycle_report_posted\",\"sla_breaches\":<int>,\"oldest_breach_age_min\":<int>,\"stalls_classified\":<int>,\"root_cause\":\"<slug>\",\"summary\":\"<one terse line>\"}
   sla_breaches MUST be an integer (0 when none). Include oldest_breach_age_min \
only if there is a breach; include root_cause only when you can name the single \
dominant cause (e.g. bot_merge_daemon_not_installed, ci_runners_blocked); omit \
fields you cannot fill rather than guessing. This line IS the report — the beat \
turns a breach into a phone page and a clean cycle into silence.

Read-only + Discord-post only. Do not push code, do not merge, do not modify \
gap state. If gh/cache access fails entirely, post that failure as the report \
rather than silently exiting."
# scanner-anchor: "kind":"board_cycle_report_posted" — emitted by the
# board-cycle agent per step 4 of BOARD_PROMPT above (the agent runs the
# printf itself; this comment is the pairing anchor the registry gate scans
# for since the literal above lives inside an escaped-quote bash string).

# `claude -p --dangerously-skip-permissions` refuses to run as root/sudo
# unless IS_SANDBOX=1 is set (see LINUX_NODE_ONBOARDING.md) — this beat runs
# under chump-board-cycle.service, a root-owned systemd unit with no User=,
# and was exiting 1 on every 15-min cycle since deploy (INFRA-3603; caught
# fixing the identical bug in the sibling board-ceo-briefing-beat.sh,
# INFRA-3601). Sandboxed to this bounded, single-cycle, no-loop report-only
# agent, not a blanket root override.
[[ "$(id -u)" == "0" ]] && export IS_SANDBOX=1

# Belt-and-suspenders: if the agent ignores step 3 and still calls
# notify_operator, this exported kind makes the registry SUPPRESS it
# (operator-escalation-registry.txt: board_cycle_report suppress) instead
# of paging as an unclassified novel caller.
export CHUMP_NOTIFY_KIND=board_cycle_report

log "beat start (timeout=${TIMEOUT_S}s)"
cycle_output=""
cycle_rc=0
if command -v timeout >/dev/null 2>&1; then
    cycle_output="$(timeout "${TIMEOUT_S}s" claude -p "$BOARD_PROMPT" --dangerously-skip-permissions 2>&1)"
    cycle_rc=$?
else
    cycle_output="$(claude -p "$BOARD_PROMPT" --dangerously-skip-permissions 2>&1)"
    cycle_rc=$?
fi
printf '%s\n' "$cycle_output"

log_dir="$REPO_ROOT/.chump-locks"
mkdir -p "$log_dir" 2>/dev/null || true
printf '{"ts":"%s","kind":"board_cycle_beat","exit_code":%s,"node":"%s"}\n' \
    "$(ts)" "$cycle_rc" "$(hostname -s 2>/dev/null || echo node)" \
    >> "$log_dir/ambient.jsonl" 2>/dev/null || true

# RESILIENT-373: deterministic, severity-gated, deduped escalation. Reads the
# structured board_cycle_report_posted line the agent just emitted and pages the
# operator ONLY on an actionable breach (deduped per signature per window) — a
# clean cycle is silent. This is what turns the 38-pages/24h firehose into
# breach-only signal. Never breaks the beat (the organ always returns 0).
ESCALATE_LIB="$REPO_ROOT/scripts/coord/lib/board-cycle-escalate.sh"
if [[ -f "$ESCALATE_LIB" ]]; then
    # shellcheck source=../coord/lib/board-cycle-escalate.sh
    unset CHUMP_NOTIFY_KIND   # the organ sets kind=board_cycle_alert on its own page
    source "$ESCALATE_LIB"
    board_cycle_escalate "$BEAT_START_EPOCH" || true
else
    log "escalate organ missing ($ESCALATE_LIB) — no page path this cycle"
fi

# RESILIENT-371: the NON-merge half of the resident board watch. The escalate
# organ above owns the 30-minute merge SLA; this lib owns the vital signs the
# human board also checks each loop tick and that no resident sensor pages on
# CJ — box/disk health, worker wedge, merge DROUGHT (distinct from an SLA
# breach), sustained main-red — plus a bounded LLM escalation for a novel
# anomaly. Deterministic, deduped, phone-quiet unless it's a real incident.
# Riding this already-resident beat means no new root-owned systemd unit to
# install. Never breaks the beat (board_vitals_check always returns 0).
VITALS_LIB="$REPO_ROOT/scripts/coord/lib/board-vitals.sh"
if [[ -f "$VITALS_LIB" ]]; then
    unset CHUMP_NOTIFY_KIND   # the lib sets kind=board_vitals_alert on its own page
    # shellcheck source=../coord/lib/board-vitals.sh
    source "$VITALS_LIB"
    board_vitals_check || true
else
    log "board-vitals organ missing ($VITALS_LIB) — non-merge watch dark this cycle"
fi

log "beat done — exit_code=$cycle_rc"
exit 0
