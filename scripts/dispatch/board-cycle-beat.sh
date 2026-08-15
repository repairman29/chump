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
3. Compose a TERSE board report (a few lines: SLA breach count + oldest \
breach age, stall classification counts, one-line fleet-health read) and \
post it to the operator via Discord: \
'source scripts/coord/lib/notify-operator.sh && notify_operator \"<report>\"'. \
Set CHUMP_NOTIFY_KIND=board_cycle_report before calling notify_operator so \
the escalation gate can classify it.
4. Append one line to .chump-locks/ambient.jsonl:
   {\"ts\":\"<utc>\",\"kind\":\"board_cycle_report_posted\",\"sla_breaches\":<n>,\"stalls_classified\":<n>}
   (only after notify_operator returns 0; skip if it failed).

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

log "beat done — exit_code=$cycle_rc"
exit 0
