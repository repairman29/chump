# Live A2A Consensus Pipeline

**Authored:** 2026-05-29 by curator-opus (INFRA-2151 / META-125 C1).
**Status:** Operator-reviewed. Ships as child C1 of META-125 umbrella.
**Closes:** [INFRA-2151](../gaps/INFRA-2151.yaml).
**Companion docs:**
- [`docs/strategy/INTEGRATION_CYCLE_2026-05-29.md`](INTEGRATION_CYCLE_2026-05-29.md) — META-124: the SHIP rhythm this composes with
- [`docs/strategy/NATS_A2A_DEMO_2026-05-28.md`](NATS_A2A_DEMO_2026-05-28.md) — the substrate this builds on
- [`docs/strategy/MARKET_POSITIONING_2026-05-27.md`](MARKET_POSITIONING_2026-05-27.md) — the 5-bet strategic compass
- [`docs/design/A2A_ROADMAP.md`](../design/A2A_ROADMAP.md) — META-061 six-layer design

---

## 1. Today's Evidence — The Manual Consensus Pattern Works

On 2026-05-29, the operator ran a 9-curator manual consensus round on the META-124 and META-125 design questions. The result was striking: each round produced substantive findings in under five minutes with two independent passes over the same material.

What that demonstrated is not fluency. Every individual curator could have produced fluent commentary in isolation. What the round demonstrated is **correctness pressure**: the harvester caught that META-125 was a port of existing proprietary code rather than a greenfield build — a finding that collapsed the estimated effort from weeks to days. That finding did not come from a single curator's read. It came from a role whose mandate said "look at the arsenal before filing anything new." The lane scope created the finding.

The operator directive issued the same day — "consensus over operator-pinging" — formalized this as fleet discipline and shipped as INFRA-2209 (PR #2757). The directive's logic: if nine curators can deliberate on a strategic question in five minutes today via a manual round-robin, the same deliberation should happen in seconds when the transport is live.

The failure mode today is timing. A broadcast goes out at 13:18. Evidence shows zero active NATS subscribers for any curator role. Replies are blocked until the next session-start for each participant — which means four to twenty-four hours per reply and days for a full round. The question is not whether the pattern works. It demonstrably does. The question is whether that latency floor is acceptable given that the substrate to eliminate it already exists.

It is not acceptable. The NATS A2A substrate landed on 2026-05-28 (INFRA-2102). Every primitive needed for live consensus — atomic CAS claims, work-board subjects, ambient event routing — is operational. The gap is a wiring problem, not an architecture problem.

---

## 2. The Proprietary Port — What Already Exists

The harvester finding from 2026-05-29 changes the implementation estimate fundamentally: META-125 is a **port**, not a build. The consensus module already exists at `chump-proprietary/crates/coord/consensus/mod.rs` (L160-235), MIT-licensed, and has been adapted once already. Its present form lives at `crates/chump-coord/src/consensus.rs` (INFRA-1803, shipped).

The module currently contains everything needed for Layer 4 consensus mechanics:

**Data types:**
- `Vote` — three variants: `Approve`, `Abort`, `Timeout`. `is_committed()` filters the meaningful signals.
- `VoteProof` — SHA256-signed record of a single vote: `signature_tag` (64-char hex), `timestamp` (RFC3339), and the vote itself. The audit trail is replayable.
- `VoteRequest` — the initiating broadcast: `vote_id`, `initiator`, `decision_type`, `reason`, `context`, `quorum`, `timeout_secs`.
- `ConsensusDecision` — the output: `Proceed`, `Abort`, or `Inconclusive`. Ties and quorum losses both land at `Inconclusive`.
- `ConsensusRecord` — the finalized round: the original request, all votes keyed by session, and the counts that produced the decision.

**Coordinator:**
- `ConsensusCoordinator` — stateful: `active_votes` (in-flight) and `completed_records` (finalized).
- `initiate_vote(request)` — opens a new vote round.
- `cast_vote(vote_id, session_id, vote)` — produces a SHA256-signed `VoteProof`.
- `finalize_vote(vote_id, votes)` — runs `ConsensusRecord::finalize`, moves the round to completed.
- `should_proceed(vote_id)` — quick query on a completed round; returns `Some(true)`, `Some(false)`, or `None` for inconclusive.

**What needs to change for META-125:**

The current `DecisionType` enum reflects an earlier operational focus: `EscalationRequired`, `ResourceCritical`, `NetworkPartitionRecovery`, `FleetScaleChange`. These are correct for fleet-internal decision-making but too narrow for strategic consensus. META-125 adds a fifth type: `AnomalyDetected` (replaces the dropped `ThreatAssessment` from the proprietary robotics domain) plus the new `StrategicPivot` type to cover roadmap-rerank decisions.

The coordinator is stateless across NATS (it runs in-process today). Wave 1 wires it to NATS subject routing. The vote-cast and finalize paths already produce the right data shapes; the publish/subscribe envelope is what is missing.

---

## 3. The Four-Step Lifecycle

The META-125 umbrella defines the canonical lifecycle. This section expands each step with operational detail.

### Step 1 — ASK

The operator or a curator fires:

```
chump consensus ask "<question>" --quorum 5 --timeout 60s --tag <strategic-tag>
```

The command generates a `consensus_id` (UUID), constructs a `VoteRequest` with the provided fields, and publishes it to `chump.events.consensus.ask`. The ambient stream receives a `kind=consensus_ask_started` event with the `consensus_id` and the question text.

The `--tag` argument matters. Tags bind a consensus round to a topic area (e.g. `meta-125-effort`, `wave-3-priority`). The pivot step in Wave 3 uses this tag to identify which gaps to re-rank.

### Step 2 — ROUTE

Each curator role runs a persistent subscriber daemon (Wave 1 C4: `chump-curator-subscriber`). The daemon listens on two subjects: `chump.events.consensus.ask` (all asks) and `chump.curator.<role>.consensus` (role-targeted asks).

On receipt, the daemon evaluates lane relevance: does this question fall within the role's scope? If yes, it triggers the per-role reasoning hook. In Wave 1 this is a `claude -p` invocation against the role's system prompt with the question as input. In Wave 3 it may route to a local MLX model for speed. The reasoning hook produces a structured output: `{vote: agree | disagree | abstain, confidence: high | med | low, rationale: string}`.

An ambient `kind=consensus_routed_to_curator` event confirms routing. If a role determines the question is outside its lane, it emits `abstain` with a rationale noting the out-of-lane determination. That signal is not noise — it shows the lane definitions are working.

### Step 3 — VOTE

Each curator's daemon publishes to `chump.events.consensus.vote.<consensus-id>`:

```
chump consensus vote <consensus-id> --vote agree --confidence high --rationale "..."
```

Internally this calls `ConsensusCoordinator::cast_vote`, producing a `VoteProof` with the SHA256 signature. The ambient stream receives `kind=consensus_vote_cast` with the curator role, vote, confidence, and rationale. Rationales are first-class — they feed the operator dashboard and the roadmap-rerank rationale field.

Confidence weighting is deferred to Wave 2 (operator pending decision below). In Wave 1 all committed votes count equally; `high` vs `med` confidence is recorded but not yet factored into the decision.

### Step 4 — RESOLVE

The `chump-consensus-aggregator-daemon` (Wave 2 C8) subscribes to `chump.events.consensus.vote.>`. At quorum or timeout (whichever comes first), it calls `ConsensusRecord::finalize`, computes the decision, and emits `kind=consensus_resolved` with the full `ConsensusRecord` JSON.

If the question was tagged for roadmap impact, the operator or the daemon can call:

```
chump consensus roadmap-pivot <consensus-id>
```

This triggers Wave 3's gap-store mutations: gaps matching the topic tag are re-ranked, superseded gaps are moved to backlogged status with a `rationale` field linking to the `consensus_id`, and the next session-summary surfaces the last N decisions. Ambient event: `kind=roadmap_rerank_applied`.

---

## 4. Three-Wave Implementation Plan

The plan is sequenced to avoid substrate risk. Wave 1 lays the NATS wiring and event vocabulary. Wave 2 builds the user-facing subcommand surface and the aggregator. Wave 3 wires consensus decisions into the gap-store and closes the loop.

### Wave 1 — Foundation (parallel-safe, no inter-child deps)

**C1** (this document) — strategy doc. Completes the design call.

**C2 — NATS subject taxonomy.** Define the canonical subjects:
- `chump.events.consensus.ask` — new consensus questions
- `chump.events.consensus.vote.<id>` — per-round vote stream
- `chump.events.consensus.resolved.<id>` — finalized round
- `chump.curator.<role>.consensus` — role-targeted delivery

Subject taxonomy lives in `docs/process/NATS_SUBJECT_TAXONOMY.md` and as constants in `crates/chump-coord/src/subjects.rs`. Both must be updated together.

**C3 — 9 new ambient event kinds.** Register in `EVENT_REGISTRY.yaml`:
`consensus_ask_started`, `consensus_routed_to_curator`, `consensus_vote_cast`, `consensus_quorum_reached`, `consensus_timeout`, `consensus_resolved`, `consensus_decision_emitted`, `roadmap_rerank_proposed`, `roadmap_rerank_applied`. These were registered as of commit 806405d12 (INFRA-2132).

**C4 — `chump-curator-subscriber` daemon.** New Rust binary at `crates/chump-curator-subscriber`. Per-role NATS subscriber; per-role reasoning hook (initially `claude -p` with role system prompt). Runs as launchd `KeepAlive` per curator role. The hook interface is a thin trait so local-MLX routing can drop in later without changing the daemon.

### Wave 2 — CLI + Aggregator (depends on C2-C4)

**C5 — `chump consensus ask` subcommand.** Publishes `VoteRequest` to NATS, returns `consensus_id`, optionally blocks-and-waits with `--wait` flag.

**C6 — `chump consensus vote` subcommand.** For curators to publish their vote manually (used in the hybrid mode where the daemon is down and the curator is running interactively).

**C7 — `chump consensus resolve` and `status` subcommands.** `status` queries in-flight rounds from NATS KV. `resolve` forces finalization when the operator wants an answer before timeout.

**C8 — `chump-consensus-aggregator-daemon`.** Rust binary. Subscribes to `chump.events.consensus.vote.>`. Calls `ConsensusRecord::finalize` at quorum-or-timeout. Emits `kind=consensus_resolved` to ambient. Writes the `ConsensusRecord` JSON to `state.db` for queryable history.

**C9 — `install-chump-consensus-launchd.sh`.** Installs the aggregator daemon as a launchd `KeepAlive` service alongside the existing fleet daemons.

### Wave 3 — Roadmap Pivot (depends on Wave 1+2)

**C10 — `chump consensus roadmap-pivot`.** Reads a finalized `ConsensusRecord` by `consensus_id`. For `ConsensusDecision::Proceed` outcomes tagged with a topic: re-prioritize matching gaps, mark superseded gaps as backlogged with the consensus rationale, and write the decision to the session-summary surface. This is the closing loop — the mechanism that makes consensus operationally binding rather than advisory.

---

## 5. Connections to META-124, META-126, META-127

### META-124 — Integration Cycles (DECIDE rhythm + SHIP rhythm compose)

META-124 defines the **SHIP rhythm**: gaps batch into integration cycles, CI runs once, a single PR ships N gaps. META-125 defines the **DECIDE rhythm**: strategic questions route to curators, votes aggregate in seconds, decisions re-rank the backlog.

These two rhythms compose cleanly because they share the NATS substrate:

- Tactical work enters the work-board and flows through integration cycles (META-124).
- Strategic pivots enter the consensus ask queue and route to curator subscribers (META-125).
- When a consensus round resolves `roadmap_rerank_applied`, the integration cycle scheduler picks up the re-ranked work-board for the next cycle.

The operator does not need to intervene between a strategic decision and a tactical re-ordering. The substrate does the handoff. This is the architecture that makes "wizard retirement" credible — the wizard role shrinks because the two automated rhythms self-compose.

### META-126 — Event-Sourced Gap Mutations

META-126 takes the next step: `chump gap reserve / update / ship / close` publishes to `chump.gap.*` subjects, and a single materializer daemon writes to `state.db` + YAMLs. This eliminates concurrent-write races at the state layer.

META-125 does not depend on META-126, but they share infrastructure assumptions. Both will publish to NATS subjects and both expect a single authoritative consumer. Implementing them in sequence (META-124 → META-125 → META-126) means the NATS JetStream configuration is established once and both systems inherit its ordering guarantees without duplication. The dependency is soft — META-126 should not block META-125 shipping — but the design should not create contradictions the META-126 pick will need to undo.

### META-127 — AI Agent Suite (curator subscribers as the live demo)

META-127's goal is to productize the 9-curator suite as an installable team for any repo. The consensus subscriber daemons from META-125 C4 are the live-demo artifact for that pitch. Today's evidence — lane-scoped curators producing correct findings in five minutes — already illustrates the value. A persistent `chump-curator-subscriber` daemon per role, running on any repo's NATS substrate, is the Marcus M-B demo moment: "here is your AI P&E team, watch them deliberate."

META-127 depends on META-125 C4 landing stably enough to demo. The sequencing is: META-125 Wave 1 ships, curator-subscriber runs in production for one integration cycle, then META-127's audit of existing roles begins from an evidence base rather than a hypothesis.

---

## 6. Cross-Links

**CLAUDE.md § On-demand docs** — add an entry:
> Live A2A consensus pipeline architecture and lifecycle: [`docs/strategy/LIVE_A2A_CONSENSUS_2026-05-29.md`](../../docs/strategy/LIVE_A2A_CONSENSUS_2026-05-29.md) (META-125 C1; read when picking any META-125 child or debugging consensus routing).

**OPERATOR_PLAYBOOK.md** — add to the "The Hierarchy" section under curator roles:
> When a strategic question arises that multiple curator roles should weigh in on, use `chump consensus ask` rather than pinging the operator. See [`docs/strategy/LIVE_A2A_CONSENSUS_2026-05-29.md`](../strategy/LIVE_A2A_CONSENSUS_2026-05-29.md) for the full lifecycle.

**docs/strategy/MARKET_POSITIONING_2026-05-27.md** — the five-bet compass named "multi-agent coordination layer for local-first" as the white space. META-125's consensus pipeline is the concrete mechanism that fills Bet 5. The cross-link should appear in the Bet 5 section of that doc: "Live consensus via META-125 is the operational expression of this bet."

---

## 7. Operator Pending Decisions

These questions are deferred to the consensus pipeline itself once it ships. Resolving them today via operator fiat would be premature — the evidence base for calibrating these parameters does not exist yet. File each as a consensus ask once Wave 2 lands.

**Quorum default.** The umbrella AC suggests 5 of 9 curators. That is a majority rule. An alternative is 3 of 9 (fast, catches obvious consensus) with a second round at 5 if the first is inconclusive. Decision: defer; default to 5 in Wave 1, revisit with data.

**Confidence weighting.** Should a `high`-confidence `agree` vote count more than a `med`-confidence `agree`? The current `ConsensusRecord::finalize` treats all committed votes as equal weight. Confidence weighting adds signal but also adds a parameter to calibrate. The `VoteProof` already records confidence; the weighting function is a one-line change. Decision: defer to a consensus ask on the question "what is the right confidence weighting formula?" once five real rounds have run.

**Auto-pivot threshold.** Should a `ConsensusDecision::Proceed` with quorum automatically trigger `roadmap-pivot`, or should the operator confirm? Auto-pivot removes operator friction; operator-confirm preserves a human checkpoint before re-ordering the backlog. Decision: default to operator-confirm in Wave 2, auto-pivot opt-in in Wave 3.

**Backlog rationale schema.** When `roadmap-pivot` marks a gap as backlogged, what goes in the `rationale` field? Minimum: `consensus_id` + one-line decision summary. Richer: full vote breakdown. Richer still: the winning rationale text from the majority curator. Decision: minimum in Wave 3 C10, richer format in a follow-up gap once the minimum runs in production.

**Curator-subscriber Rust binary vs. `claude -p` managed by tmux.** Wave 1 C4 calls for a Rust binary daemon with a `claude -p` subprocess hook. An alternative is a shell script per role launched by the existing tmux-managed fleet. The Rust binary is preferred (durable, restartable, typed interfaces) but adds a new crate. The tmux approach reuses existing infrastructure. Decision: Rust binary per the Rust-first criteria in CLAUDE.md (durable tooling, mutates ambient stream, will outlive 3 months) but use the `claude -p` hook to stay within the existing auth path. The binary is a thin supervisor, not a reasoning engine.
