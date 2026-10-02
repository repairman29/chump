# No-operator-escalation discipline (operator-decision-of-record 2026-05-30)

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

> **Operator directive 2026-05-30T17:30Z (verbatim):** *"Make sure the
> don't escalate to the human protocol is locked in for agents. I'm not
> here to babysit. I'm here for results."*

**Default mode is team consensus, not operator escalation.** When an agent
faces a decision that isn't trivially their own, broadcast a `FEEDBACK
kind=proposal` to peer curators (see [`OPUS_MESSAGE_PROTOCOL.md`](./OPUS_MESSAGE_PROTOCOL.md)),
let the deliberator-loop tally votes, and act on `kind=consensus_resolved`.

## The 4 legitimate escalation triggers (the ONLY ones)

| Code | Trigger | Example |
|------|---------|---------|
| **T1** | Irreversible third-party action with no consensus mandate | Production deploy beyond chump itself; financial spend; external comms to partners/customers/lawyers |
| **T2** | Credential rotation requiring operator hands-on-keyboard | R2 token rotation; OAuth setup; SSH key provisioning on new hardware |
| **T3** | Operator-explicit-domain decisions | Legal / license model; partnership pitches; pricing; public branding/messaging |
| **T4** | Halt-class fleet condition where consensus itself is unsafe | trunk-RED **AND** auth-storm **AND** queue-starve simultaneously; deliberator-loop down; broadcast.sh broken |

**Everything else → team consensus.** Before `AskUserQuestion` or
`scripts/dispatch/operator-recall.sh`, run through the 4 triggers. None
match → broadcast `FEEDBACK kind=proposal` instead.

## Legitimate vs illegitimate examples

| Situation | Legitimate channel |
|-----------|--------------------|
| "Should I close this stale PR?" | Team consensus; illegitimate to ask operator |
| "Which of these 4 design options?" | Team consensus; illegitimate to AskUserQuestion |
| "Should I admin-merge this PR?" | Team consensus via the relevant consensus gate; illegitimate unless T4 |
| "Should I push the R2 cred rotation?" | **T2** — operator escalation legitimate |
| "Trunk red on 4 surfaces, deliberator down" | **T4** — operator escalation legitimate |
| "Should we partner with Anthropic?" | **T3** — operator escalation legitimate |

## Enforcement

- Detector emits `kind=operator_escalation_unjustified` when an agent
  invokes operator-escalation outside the 4 triggers.
- Audit: `scripts/dev/operator-escalation-leaderboard.sh`.
- SLO: < 1 unjustified escalation per fleet-day.
- Extends to sub-agents via `docs/process/SUBAGENT_DISPATCH.md`.
