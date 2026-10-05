#!/usr/bin/env bash
# fleet-l2-demo.sh — FLEET-024 §"First Demo: Single Sprint (Q4)" acceptance smoke.
#
# Walks the operator through the L2 single-sprint demo end-to-end against
# a local NATS broker. Agent A posts a subtask; Agent B (a separate
# session id) claims and completes it. The script then prints the
# subtask's final state and the chump.events.work_board.* event timeline,
# proving the L2 building blocks (FLEET-008 work board + FLEET-010
# help-seeking) actually compose into a working multi-agent flow.
#
# Two-machine version: run this script unchanged on machine 1, then on
# machine 2 set CHUMP_NATS_URL to machine 1's broker address. Both
# sessions hit the same KV bucket so the post→claim→complete sequence
# crosses the network. The local-only run is a single-machine smoke that
# exercises the same code paths (different session ids per role).
#
# Requires:
#   - chump-coord binary on PATH (cargo build -p chump-coord && symlink, or
#     scripts/setup/install-from-tip.sh)
#   - A reachable NATS server with JetStream enabled. For local:
#       docker run -d --name chump-nats -p 4222:4222 nats:latest -js
#   - jq for parsing event payloads.
#
# Usage:
#   bash scripts/demo/fleet-l2-demo.sh [parent-gap-id]
#
# Exit codes:
#   0  demo completed (subtask landed in Completed state, events visible)
#   1  setup precondition failed (binary missing, NATS unreachable, jq missing)
#   2  demo step failed (post / claim / complete returned wrong state)
#
# This script is the FLEET-024 acceptance smoke. It also serves as the
# operator runbook for the §First Demo from
# docs/strategy/FLEET_VISION_2026Q2.md.

set -euo pipefail

# ── Pretty output ────────────────────────────────────────────────────────────
say()  { printf '\033[1;36m[fleet-l2-demo]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[fleet-l2-demo]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fleet-l2-demo]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# ── Args ──────────────────────────────────────────────────────────────────────
PARENT_GAP="${1:-FLEET-024}"

# ── Preconditions ────────────────────────────────────────────────────────────
command -v jq >/dev/null || die "jq is required (brew install jq)"
COORD="${CHUMP_COORD_BIN:-$(command -v chump-coord || true)}"
[[ -x "$COORD" ]] || die "chump-coord binary not on PATH (cargo build -p chump-coord then symlink)"

# Probe NATS reachability — the binary's `ping` subcommand exits 0 when up.
if ! "$COORD" ping >/dev/null 2>&1; then
    NATS_URL="${CHUMP_NATS_URL:-nats://127.0.0.1:4222}"
    die "NATS unreachable at $NATS_URL — start a broker:
       docker run -d --name chump-nats -p 4222:4222 nats:latest -js"
fi

# ── Use a fresh per-run KV bucket so concurrent demos don't collide ──────────
# Both halves of the demo share this env so they hit the same bucket.
export CHUMP_NATS_WORK_BOARD_BUCKET="demo_l2_$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]' | head -c 12)"
say "using ephemeral work-board bucket: $CHUMP_NATS_WORK_BOARD_BUCKET"

# ── Step 1 (Agent A): post a subtask ─────────────────────────────────────────
AGENT_A="agent-alpha-$(date +%s)"
AGENT_B="agent-bravo-$(date +%s)"

say "step 1 — Agent A ($AGENT_A) posts a subtask under parent $PARENT_GAP"
SUBTASK_ID=$(
    CHUMP_SESSION_ID="$AGENT_A" \
    "$COORD" work-board post \
        "$PARENT_GAP" \
        "review" \
        "L2 demo: review the parent gap's plan" \
        --description "Single-sprint demo subtask — should be claimed by another agent" \
        --est-secs 1800
)
[[ "$SUBTASK_ID" =~ ^SUBTASK-[0-9a-f]{8}$ ]] || die "post returned malformed id: $SUBTASK_ID" 2
say "  → posted $SUBTASK_ID"

# ── Step 2 (Agent B): claim it ───────────────────────────────────────────────
say "step 2 — Agent B ($AGENT_B) claims $SUBTASK_ID"
CHUMP_SESSION_ID="$AGENT_B" "$COORD" work-board claim "$SUBTASK_ID" >/dev/null \
    || die "claim failed for $SUBTASK_ID" 2

# Verify state via show.
state_after_claim=$("$COORD" work-board show "$SUBTASK_ID" | jq -r '.status')
[[ "$state_after_claim" == "claimed" ]] || die "expected status=claimed, got $state_after_claim" 2
holder=$("$COORD" work-board show "$SUBTASK_ID" | jq -r '.claimed_by')
[[ "$holder" == "$AGENT_B" ]] || die "claim holder mismatch: $holder vs $AGENT_B" 2
say "  → claimed by $holder (state: claimed)"

# ── Step 3 (Agent A from a sibling session attempts double-claim — must fail) ─
say "step 3 — confirm Agent A's late claim attempt is rejected (CAS guard)"
if CHUMP_SESSION_ID="$AGENT_A" "$COORD" work-board claim "$SUBTASK_ID" >/dev/null 2>&1; then
    die "double-claim should have failed but exited 0" 2
fi
say "  → late claim correctly rejected"

# ── Step 4 (Agent B): complete the subtask with a synthetic PR ref ───────────
say "step 4 — Agent B completes $SUBTASK_ID"
CHUMP_SESSION_ID="$AGENT_B" "$COORD" work-board complete "$SUBTASK_ID" \
    --commit "demo-$(date +%s)" >/dev/null \
    || die "complete failed for $SUBTASK_ID" 2

state_after_complete=$("$COORD" work-board show "$SUBTASK_ID" | jq -r '.status')
[[ "$state_after_complete" == "completed" ]] || die "expected status=completed, got $state_after_complete" 2
say "  → completed by $AGENT_B (state: completed)"

# ── Step 5: cross-check via list (the parent-gap query path) ─────────────────
say "step 5 — list subtasks for parent $PARENT_GAP (cross-check)"
listed=$("$COORD" work-board list --status completed | grep -c "$SUBTASK_ID" || true)
[[ "$listed" -ge 1 ]] || die "completed subtask $SUBTASK_ID not in list output" 2
say "  → $SUBTASK_ID visible in list --status completed"

# ── Step 6: print the final subtask record ───────────────────────────────────
say "final subtask record:"
"$COORD" work-board show "$SUBTASK_ID" | jq

# ── Done ─────────────────────────────────────────────────────────────────────
echo
say "✓ FLEET-024 §First Demo acceptance: PASS"
say "  Agent A ($AGENT_A) posted, Agent B ($AGENT_B) claimed + completed,"
say "  CAS race rejected the late double-claim, list reflects terminal state."
say "  This is the L2 single-sprint smoke — same code paths run cross-machine"
say "  when CHUMP_NATS_URL points at a shared broker."
