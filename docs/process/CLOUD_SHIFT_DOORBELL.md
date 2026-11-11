# Cloud-shift doorbell contract (INFRA-8070)

Origin: bus proposal `ops.shift-wake-proposal` (cloud-default, 2026-10-04). NATS is a mailbox, not a doorbell;
this adds the doorbell. Draft for landing in `chump-proprietary/nats` (operator lands; that repo is not
reachable from this tree, so the waker ships here as `scripts/coord/cloud-shift-doorbell.sh`).

## Waker (cuphead service)
`scripts/coord/cloud-shift-doorbell.sh tick`, run from a timer. Fires the existing Chump-Cloud-Agent routine
through the claude.ai RemoteTrigger run API (OAuth token; `CHUMP_ROUTINE_RUN_URL`) when there is eligible
dispatch work OR a queued reply on the `cloud-default` consumer. Firing an existing routine is allowed;
*creating* a keyed routine stays a one-time human step.

Trigger-side guards: min 15 min between fires (`CHUMP_DOORBELL_MIN_GAP_S=900`, failed fires count);
stop after 3 consecutive junk/fail (`record junk|fail`; `reset` re-arms); `FLEET_DISPATCH_PAUSED`
(env or state-dir file) halts all fires. Only `mac-claude-code` may fire the routine for now.

## Shift protocol
1. Read the NATS queue BEFORE taking any task; apply replies first.
2. A message on `ops.hold` from `mac-claude-code` ends the shift without leasing anything
   (`ops.hold` from other senders is ignored).
3. On any non-empty-queue exit, publish `ops.shift-report` stating what the shift needs.
4. At end, `cloud-shift-doorbell.sh record ok|junk|fail` so the circuit breaker counts it.

Test: `scripts/ci/test-cloud-shift-doorbell.sh`.
