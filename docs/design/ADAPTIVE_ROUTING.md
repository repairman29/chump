# Adaptive routing — the two bandit implementations (INFRA-1573)

Chump has two Thompson-sampling bandits. They are algorithm-identical
(Beta(α, β) posteriors sampled via the Gamma-ratio trick, plus a UCB1
fallback helper) but route disjoint vocabularies:

| | `crates/chump-orchestrator/src/thompson.rs` (COG-037) | `src/provider_bandit.rs` (`BanditRouter`) |
|---|---|---|
| Arm type | `crate::routing::Candidate` — `(backend, model, provider_pfx)` | `ProviderSlot` name |
| Scope | Cross-backend dispatch (pick which backend/model/provider to route a whole request to) | In-cascade slot selection (pick which slot within a single provider cascade to try next) |
| State | Pure function — caller owns `ArmStats` map, passes `&mut Rng` per call | `Mutex`-guarded internal state, updated in place via a reward callback |
| Crate | `chump-orchestrator` (its own release cadence) | root `chump` crate |
| LOC | 315 | 586 |

## Decision: keep separate

**Rationale:**

1. **Release-cadence independence.** `chump-orchestrator` ships on its own
   crate boundary; `src/provider_bandit.rs` lives in the root binary crate.
   A shared `crates/chump-bandit` dependency would couple their release
   schedules for a ~150-LOC core (the actual Beta-sampling logic is small;
   most of each file's LOC is call-site plumbing, `ArmStats`/`ProviderSlot`
   bookkeeping, and tests).
2. **Blast-radius isolation.** The two bandits pick fundamentally different
   things (which backend to dispatch to, vs. which slot to retry within a
   cascade) at different points in the request lifecycle. A regression in
   one must not be able to reach the other through a shared abstraction.
3. **Different concurrency models.** `thompson.rs` is pure-function +
   caller-supplied `&mut Rng`, designed to be called from single-threaded
   ranking code. `provider_bandit.rs` wraps its state in a `Mutex` because
   the cascade calls it from multiple concurrent request paths. Forcing both
   into one generic `BanditRouter<Arm>` would mean either threading a
   locking strategy through the pure-function caller (unnecessary overhead)
   or giving the orchestrator's ranking path unnecessary `Mutex` contention.
4. **Genericizing `Arm: Eq + Hash + Clone + Display` buys little.** The
   actual duplicated surface is the Beta-sampling math (~30 LOC) and the
   UCB1 helper (~20 LOC) — extracting *that* into a shared crate for two
   call sites, each with different state-ownership models, trades a small
   amount of duplication for a permanent cross-crate coupling. Not worth it
   at this scale; revisit if a third bandit consumer appears.

This is the META-063 redundancy pattern (two implementations of the same
algorithm, each written for its own scope) — see `AGENTS.md` §
[Redundancy prevention](../../AGENTS.md#redundancy-prevention-meta-063) for
the general policy and the exception recorded for this pair.

Cross-link comments pointing each file at the other (with this rationale
summarized inline) already live at the top of both
[`crates/chump-orchestrator/src/thompson.rs`](../../crates/chump-orchestrator/src/thompson.rs)
and [`src/provider_bandit.rs`](../../src/provider_bandit.rs).

## How the two bandits compose in live dispatch

Both bandits are learned-policy layers sitting on top of Chump's routing:

1. **Cross-backend dispatch** (`thompson.rs`, COG-037) picks *which backend
   to route a request to* — e.g. ChumpLocal vs. Claude vs. another
   configured backend — by ranking `Candidate` arms via Thompson sampling
   over historical success/failure counts per `(backend, model,
   provider_pfx)` signature.
2. **In-cascade slot selection** (`provider_bandit.rs`, `BanditRouter`)
   operates *within* a single provider's cascade, once dispatch has already
   picked a backend: given a hand-configured priority order over
   `ProviderSlot`s (e.g. local → cloud-A → cloud-B), it learns which slot
   actually performs best for the current workload and steers traffic
   there instead of always trying the hard-coded priority order first.

In short: `thompson.rs` answers "which backend/model should this request
go to at all?"; `provider_bandit.rs` answers "given that backend, which
slot inside its cascade should be tried first this turn?" They are
adjacent layers in the same dispatch pipeline, not competing
implementations of the same decision.
