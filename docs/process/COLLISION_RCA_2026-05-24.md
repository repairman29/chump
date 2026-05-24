# Curator Claim-Collision RCA — 2026-05-24

> **Read this on session start.** Operator-directed RCA after three curator
> claim-collisions in a single afternoon. Two protocol changes below. Each
> opus-curator session must apply them on next start.

## TL;DR

Three collisions today. **Two preventable, one was the model.** The lease-CAS
correctly serialized *concurrent* claims, but the fleet has no protocol for
*sequential* claims and no claimer-of-record handshake on ASSIGNMENT-ASK
alerts. Two protocol changes below; both are 1-paragraph additions to
[`OPUS_SHEPHERD_PLAYBOOK.md`](./OPUS_SHEPHERD_PLAYBOOK.md) and apply to all
curator-loop scripts.

## Timeline (UTC, 2026-05-24)

| Time | Event |
|---|---|
| 18:13Z | orchestrator-opus-2026-05-24 pings opus-shepherd-generalist for role-identity dedup (shared session-id, separate role). |
| 18:17Z | opus-autopilot green-lights INFRA-1923 re-dispatch (ci-audit productize): "Go ahead — prefer (a)." |
| 18:24Z | opus-curator-overnight files INFRA-1950 P0/m (TRUNK-RED, pre-push hook env-leak); broadcasts ASSIGNMENT-ASK ALERT to 3 sessions with options (a)/(b)/(c). |
| 18:26Z | orchestrator-opus-2026-05-24 broadcasts STATUS-PULL: wake-mode + pillar-lane confirmations within 10min. |
| 18:27Z | opus-curator-overnight broadcasts COLLISION HEADS-UP: INFRA-1927 vs INFRA-1950 both touch `scripts/git-hooks/pre-push`, diff-check shows no semantic conflict. **(Clean case.)** |
| 18:29Z | opus-autopilot replies to STATUS-PULL: event-driven (b), pillar = EFFECTIVE primary. |
| 18:30Z | opus-curator-overnight replies to STATUS-PULL: event-driven (b), pillar = MISSION (Harvester), secondary RESILIENT ad-hoc. |
| 18:30Z | opus-curator-overnight OFFERS to take INFRA-1950 itself (option c): "Will start now unless you object within 5 min." |
| 18:33Z | opus-shepherd-generalist (this session) dispatches a Sonnet sub-agent on INFRA-1950 (no green-light, no objection-window check). |
| 18:33Z | opus-shepherd-generalist sub-agent's `chump claim INFRA-1950` wins; opens **#2539**. |
| 18:34Z | curator-opus-shepherd's Sonnet dispatches on INFRA-1950, opens **#2540** (~69s after #2539). |
| 18:50Z | Operator observes the duplicate. |
| 18:59Z | opus-curator-overnight broadcasts DUPLICATE-PR + RCA REQUEST: pick winner + write this document. |
| 19:21Z | orchestrator-opus broadcasts HOLD: curators hold new ship work until shepherd unblocks trunk. |
| (later) | #2540 closed as duplicate; #2539 retained as canonical. |

## Collisions and how each played out

### Collision 1 — INFRA-1950: dual Sonnet dispatch, two armed PRs

opus-curator-overnight's 18:24Z ALERT carried an explicit ASSIGNMENT-ASK with
3 options. **No session replied claiming any option before claiming.**
opus-curator-overnight offered to take it at 18:30Z with a 5-minute
objection window; the window had not elapsed when opus-shepherd-generalist
dispatched a Sonnet at 18:33Z. ~69 seconds later, curator-opus-shepherd
also dispatched a Sonnet. Both reached `chump claim INFRA-1950`; the lease
CAS serialized them so only one held the lease at a time, but both Sonnets
had already cd'd into worktrees and started writing the same fix. Both
opened PRs (#2539 + #2540) with auto-merge armed.

**Why the lease CAS didn't prevent this**: the lease catches a single instant
in time. The second Sonnet's `chump claim` returned "live-claimed" — but
the dispatching shepherd's prompt didn't tell it to abort cleanly on that
signal; it had the manual-recovery fallback, which created a new worktree
manually and shipped anyway.

### Collision 2 — INFRA-1923: cross-shell green-light leak

opus-autopilot green-lit opus-curator-overnight to re-dispatch INFRA-1923
at 18:17Z. ~16 minutes later, opus-shepherd-generalist (running in the
same Claude Code shell as opus-autopilot, but a different role-alias)
claimed INFRA-1923 itself and dispatched a Sonnet.

**Why this happened**: role-aliases sharing a session-id aren't visible
as distinct actors to peers. opus-curator-overnight had no way to know
that "opus-shepherd-generalist" was a *different* role from
"opus-autopilot" in the same shell, even though they have different
fleet-registry entries and different lanes. The green-light went to one
role, but a sibling role in the same shell ignored it.

Lease conflict avoided only because opus-curator-overnight pivoted to
INFRA-1950 in between (16 minutes is long enough to pick another gap).
Pure luck.

### Collision 3 — INFRA-1927 vs INFRA-1950: handled cleanly. THE MODEL.

Two gaps both targeting `scripts/git-hooks/pre-push`. opus-curator-overnight
broadcast a COLLISION HEADS-UP at 18:27Z with: (a) explicit diff-check
showing the two PRs edit different line ranges, (b) explicit ordering
("INFRA-1950 must ship FIRST because it unblocks #2537"), (c) offer of
ownership, (d) 5-minute objection window.

**No collision occurred** because the heads-up gave peers explicit
information to coordinate around. This is the protocol the other two
collisions should have used.

## Underlying mechanism gaps

1. **No claimer-of-record handshake on ASSIGNMENT-ASK alerts.** Today's model
   is "first chump claim wins." For a routine pick that's fine. For an
   explicit ALERT with options, it produces races (Collision 1).

2. **Role-aliases in same shell are invisible to peers.** Sessions that
   broadcast under the same session-id but operate as different roles
   (`opus-autopilot`, `opus-shepherd-generalist`, occasionally an
   `orchestrator-opus-<date>` thread) appear identical from outside
   (Collision 2). The fleet-registry lists them as separate roles but the
   broadcast `session` field is the IDE-instance, not the role.

3. **Lease CAS only catches concurrent claims at one instant.** Sequential
   claims that fail the CAS still leak through if the dispatching code
   has manual-recovery fallback that bypasses the CAS (Collision 1).

4. **No PR-level dedup before opening.** A sub-agent that dispatches on a
   gap will preflight + claim, but won't search GitHub for "is there
   already an open PR with this gap-id in its title?" before pushing.
   Open PRs from a prior dispatch survive lease expiry.

## Protocol changes (apply on next session start)

### Change 1 — Claim-of-record handshake on ASSIGNMENT-ASK alerts

When a curator broadcasts an ALERT with options (e.g. "(a) dispatch
Sonnet, (b) hand to X, (c) I'll take it"), the responding curator
**must** broadcast a `CLAIMING <gap-id> via option <X>` event before
running `chump claim`. The CLAIMING broadcast carries an implicit
60-second objection window. Other curators considering the same gap
**must** check ambient for a CLAIMING event in the last 60s before
claiming themselves.

Concrete:

```bash
# Before chump claim on a gap referenced in an ASSIGNMENT-ASK ALERT:
scripts/coord/broadcast.sh CLAIMING <GAP-ID> via=<option> rationale=<one-line>

# Then sleep 60s and re-check ambient for objections:
sleep 60
if grep "\"kind\":\"OBJECTION\".*<GAP-ID>" .chump-locks/ambient.jsonl | tail -5 | recent_60s; then
    echo "claim contested; deferring"
    exit 0
fi

# Then claim
chump claim <GAP-ID>
```

This adds 60s of latency on contested claims; routine picks (no
preceding ALERT) skip the handshake.

### Change 2 — Sub-agent dispatch must PR-dedup by gap-id

Every Opus orchestrator that dispatches a Sonnet sub-agent on a gap
**must** preflight-check for an already-open PR referencing the gap-id
in its title before calling the Agent tool. If found: do not dispatch;
broadcast a CONSOLIDATING event pointing at the existing PR. If the
existing PR is stale (closed-not-merged or DIRTY >2h), the dispatcher
may re-dispatch with a CONSOLIDATING-OVER comment on the closed PR.

Concrete:

```bash
EXISTING=$(gh pr list --search "in:title <GAP-ID>" --state open --json number --jq '.[0].number' | head -1)
if [[ -n "$EXISTING" ]]; then
    scripts/coord/broadcast.sh CONSOLIDATING <GAP-ID> existing_pr=#$EXISTING
    echo "PR #$EXISTING already exists for <GAP-ID>; not dispatching."
    exit 0
fi
# else proceed to Agent dispatch
```

This catches the Collision-1 class even when the lease has expired
between claim and dispatch.

## Out-of-scope but worth filing as follow-ups

- **Depth-of-trunk-red metric.** Today's TRUNK-RED WAVE 2 (post INFRA-1950
  fix) revealed 57/60 main CI runs had been failing while the
  CHUMP_SELF_HOSTED_ENABLED flag masked it as "queued forever." There is
  no metric for "trunk-red depth" — a separate gap.
- **Role-alias publication.** opus-autopilot / opus-shepherd-generalist /
  orchestrator-opus-2026-05-24 share session-id chump-Chump-1776471708 but
  are distinct roles. A `chump role announce <role-name>` primitive
  would let peers see role-cards rather than guessing from broadcast
  signatures.

Each of these can be filed separately; not in scope here.

## Read-on-next-session-start

Every opus-curator session opens with the MANDATORY pre-flight in
[`CLAUDE.md`](../../CLAUDE.md). Add this document to that list. Goal: zero
re-occurrence of Collision 1 + Collision 2 patterns by next 24h.
