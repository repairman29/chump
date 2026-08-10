#!/usr/bin/env bash
# pr-lander-beat.sh — RESILIENT-288. The automated ATC ship-lander beat.
#
# WHY THIS EXISTS. Getting green work merged onto main is the fleet's core job,
# and it was left to an agent "remembering" to sweep — the single biggest failure
# mode of an AI operator. On 2026-08-10 PR #3584 sat CLEAN + MERGEABLE + all-green
# for 3.5h and never merged: its worker ended its turn before bot-merge armed
# auto-merge (the CREDIBLE-233 / RESILIENT-286 orphan-churn). The daemon whose
# whole job is to arm such PRs — auto-arm-sweeper.sh (INFRA-374) — was scheduled
# NOWHERE: not on the Mac, and not on helsinki (the primary node that now does all
# the shipping ran zero PR-lifecycle daemons). So green PRs orphaned until the
# reaper eventually closed them. This beat bakes the sweep into the OS: a node
# timer runs it every ~10 min, so no human and no agent has to remember.
#
# THE BEAT (each step is idempotent + logs; a step failing never aborts the rest):
#   1. Arm auto-merge on any OPEN, non-draft, non-WIP, non-DIRTY PR that lost or
#      never got its auto-merge state (auto-arm-sweeper.sh / INFRA-374).
#   2. Emit an observable ambient event so the beat's work is VERIFIABLE, not
#      assumed — "the loop is running" must be provable (DURABLE_FIX_DOCTRINE).
#
# Runs on the always-on primary node (helsinki) via chump-pr-lander.timer.
# Idempotent + safe to run from cron/systemd/by hand. Read-mostly: it only arms
# PRs the current gh user authored; it never force-pushes or closes.
#
# Usage:
#   bash scripts/dispatch/pr-lander-beat.sh              # apply
#   bash scripts/dispatch/pr-lander-beat.sh --dry-run    # report only
#
# Global off-switch: CHUMP_PR_LANDER_SKIP=1.
set -uo pipefail

[[ "${CHUMP_PR_LANDER_SKIP:-0}" == "1" ]] && { echo "[pr-lander] CHUMP_PR_LANDER_SKIP=1 — exit"; exit 0; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "[pr-lander] cannot cd repo root" >&2; exit 1; }

DRY_FLAG=""
[[ "${1:-}" == "--dry-run" ]] && DRY_FLAG="--dry-run"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[pr-lander %s] %s\n' "$(ts)" "$*"; }

# Keep the local main current so mergeability reads are fresh (best-effort).
git fetch origin main -q 2>/dev/null || true

# ── Step 1: arm unarmed green PRs ────────────────────────────────────────────
log "beat start${DRY_FLAG:+ (dry-run)}"
arm_out="$(bash "$REPO_ROOT/scripts/ops/auto-arm-sweeper.sh" $DRY_FLAG 2>&1)"
printf '%s\n' "$arm_out"
armed_n="$(printf '%s' "$arm_out" | sed -n 's/.*summary: armed=\([0-9]*\).*/\1/p' | tail -1)"
armed_n="${armed_n:-0}"

# ── Step 2: emit an observable ambient event (verify, don't assume) ──────────
if [[ -z "$DRY_FLAG" ]]; then
    log_dir="$REPO_ROOT/.chump-locks"
    mkdir -p "$log_dir" 2>/dev/null || true
    printf '{"ts":"%s","kind":"pr_lander_beat","armed":%s,"node":"%s"}\n' \
        "$(ts)" "$armed_n" "$(hostname -s 2>/dev/null || echo node)" \
        >> "$log_dir/ambient.jsonl" 2>/dev/null || true
fi

log "beat done — armed=$armed_n"
exit 0
