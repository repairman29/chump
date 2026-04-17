# Making Chump the Rust Agent Standard

**Goal:** Chump is both (a) the best local-first personal AI product and (b) the authoritative Rust framework other people build on. Not one or the other.

**Status:** 2026-04-17. The Rust-agents landscape has one serious incumbent (OpenJarvis, Stanford Scaling Intelligence Lab, 2761 stars in ~2 months, Python-first with 17 Rust backing crates). Chump has more and better code but it's all in one binary crate — unusable as a library. This plan closes that gap while doing real product work at the same time.

---

## Current state vs OpenJarvis (evidence, not marketing)

| | OpenJarvis | Chump (2026-04-17) |
|---|---|---|
| Rust LOC | 26,761 | 66,620 (**2.5× more**) |
| Architecture | 17 library crates + Python via PyO3 | 1 binary crate + 4 helper crates |
| Public crates | 17 (namespaced `openjarvis-*`) | 0 for agent primitives; 4 MCP servers + 1 macro |
| Stars | 2761 | — |
| Research backing | Stanford Scaling Intelligence Lab | Solo builder |
| Energy telemetry | Trait scaffold + `is_available() = false` stubs | **Working `powermetrics` impl on Apple Silicon** (shipped in this plan) |
| Bandit routing | Thompson + UCB1 (~80 LOC, real) | Fall-through cascade (no learning) |
| MCP bridge | 270 LOC, stateless | 900+ LOC with per-session lifecycle |
| Multi-agent coordination | Not mentioned | Full lease + hook + CI suite |
| Cognitive substrate | ReAct + Orchestrator + Operative role names | Active inference + neuromod + precision controller + belief state |
| Language binding | PyO3 wrapper for researchers | None yet |
| Public benchmark | "88.7% of single-turn queries at interactive latency" | None yet |

**Read:** they're playing the framework-adoption game with a thin working stack. We're playing the product-excellence game with a deep monolith. The winning path is to combine both.

---

## Strategy

### Pillar 1: Publish our unique primitives as crates

We ship the **first** working public crate for things OpenJarvis either doesn't have or has only as a sketch. Order of extraction (priority = uniqueness × maturity):

1. **`chump-agent-lease`** — multi-agent coordination via path-level leases. **Shipped 2026-04-17.** OpenJarvis has nothing equivalent; this is our flagship differentiator for "serious about many agents in one repo."
2. **`chump-cognition`** — active inference + neuromodulation + precision controller + belief state. Research-grade, more sophisticated than OpenJarvis's role names. Needs API polish to extract cleanly from `src/`.
3. **`chump-mcp-lifecycle`** — per-session MCP server spawning (what we shipped as ACP-001). OpenJarvis's MCP crate is thin + stateless; ours handles the full ACP `session/new → session/cancel → reap` cycle with a Drop cascade.
4. **`chump-agent-matrix`** — the dogfood matrix runner as a standalone crate so any Rust agent can drop it in for runtime regression coverage. OpenJarvis doesn't publish anything like this.
5. **`chump-telemetry-energy`** — the energy monitor we just landed. Working implementations, not stubs. (Currently under `src/`; extract when stable.)
6. **`chump-core`** — foundation types (message, tool, session, provider). Matches OpenJarvis's `openjarvis-core`. Must come early but NOT first — nail the unique crates first so we don't look like a me-too.

**Staging:** each crate gets its own `README.md` + keyword + category + docs.rs badge before first publish. Publish via `cargo publish` one at a time, not in a batch — easier to diagnose name conflicts with what's already on crates.io.

### Pillar 2: Close the three real capability gaps

OpenJarvis beats us on **three specific things** and we should close each with superior implementations:

#### 2a. Energy telemetry — **SHIPPED THIS SESSION** (`src/telemetry_energy.rs`)

- Trait mirrors `openjarvis::telemetry::energy::EnergyMonitor` field-for-field → interop is one trait-impl away.
- Working `ApplePowermetricsMonitor` with real joules/watts/temperature/utilization. Their equivalent is `is_available() = false`.
- Fallback `NullMonitor` for platforms we haven't implemented yet — zero readings, always honest.
- `NvidiaSmiMonitor` scaffold for Linux + NVIDIA (fill in when we have a Linux dev box).

Tests: 8 unit tests, all passing.

#### 2b. Bandit-based provider routing — NEXT

Their `BanditRouterPolicy` does Thompson Sampling + UCB1 across model names and tracks per-arm rewards. Plan:

- Add `src/provider_bandit.rs` with the same surface.
- Wire into `src/provider_cascade.rs` so slot selection is learned from task outcomes rather than hand-configured fallback order.
- Reward signal: turn success × (1 / latency). Maybe energy per token once the energy monitor is live.
- Exact reference implementation: `rust/crates/openjarvis-learning/src/bandit.rs` in the OpenJarvis repo. Reimplement; don't adapt — theirs is Apache-2.0 and we're MIT.

Scope: ~2 days of real work. Payoff: provider_cascade stops being a hand-edited list and becomes a measurable win.

#### 2c. Local fine-tuning (LoRA / GRPO / SFT) — BIGGEST

OpenJarvis's `openjarvis-learning` crate has 6281 LOC covering SFT, LoRA adapters, GRPO, skill discovery, and reward models. This is the most expensive to match. Steps:

1. Gate all of it behind a `chump-training` feature flag (not core).
2. Depend on `mistral.rs` + `candle` for Rust-native training; avoid a Python dependency to preserve our "Rust-first" story.
3. Start with LoRA over a 3B base — smallest useful scale for solo-dev iteration.
4. Close the loop with our reflection system (COG-*) so lessons become training examples.

Scope: multi-week feature, scope carefully. Not required for "Rust agent standard" credibility on day one.

### Pillar 3: Public benchmark number

OpenJarvis's loud claim is "88.7% of single-turn queries at interactive latency." That's our floor to beat or match with our own number. Plan:

- Build `scripts/chump-bench.sh` that runs our scenario mix against a stable model + config.
- Report pass rate + p50/p95 latency + joules-per-query (energy monitor!) + accuracy-vs-GPT-4 (LLM-as-judge, already have).
- Publish the results file in `docs/BENCHMARKS.md` with a plot and a "reproduce locally" section.
- Update README to quote the number.

Scope: ~1 day of plumbing + overnight runs.

### Pillar 4: Positioning docs

Three deliverables:

1. **`README.md`**: lead with "THE Rust-native local-first agent framework" framing. Mention the crates, the benchmark, the coordination system. Link to the comparison with OpenJarvis.
2. **`docs/WHY_CHUMP_NOT_OPENJARVIS.md`**: honest, evidence-based comparison. Three sections: "where we're ahead", "where we're behind and closing", "when you should pick OpenJarvis instead." Last section is counterintuitive but builds trust.
3. **`docs/LIBRARY_ADOPTION_GUIDE.md`**: for downstream crate consumers. Which crate solves your problem. Example code for each.

---

## Milestones + rough timeline

| Milestone | Deliverable | Effort |
|---|---|---|
| M1 | `chump-agent-lease` crate extracted (publish pending) | **✅ shipped 2026-04-17** |
| M1 | `src/telemetry_energy.rs` with working Apple Silicon impl | **✅ shipped 2026-04-17** |
| M1 | `docs/RUST_AGENT_STANDARD_PLAN.md` + README positioning refresh | **✅ shipped 2026-04-17** |
| M2-a | Bandit routing wired into `provider_cascade` | **✅ shipped 2026-04-17** (`e407866`) |
| M2-b | Public benchmark script + `docs/BENCHMARKS.md` scaffolding | **✅ shipped 2026-04-17** (`281f71a`) |
| M2-c | `chump-mcp-lifecycle` crate extraction | **✅ shipped 2026-04-17** (`fecf45f`) |
| M4-a | `docs/WHY_CHUMP_NOT_OPENJARVIS.md` — honest comparison | **✅ shipped 2026-04-17** |
| M4-b | `docs/LIBRARY_ADOPTION_GUIDE.md` — crate consumer guide | **✅ shipped 2026-04-17** |
| M3-a | `chump-cognition` crate extraction (heavy coupling — 17 files ref `blackboard`, 16 ref `precision_controller`) | ~1 week focused work |
| M3-b | `chump-core` foundations (Message, Tool, Session, Provider) | ~1 week |
| M3-c | First real benchmark result row in `docs/BENCHMARKS.md` | ~1 day plumbing + overnight runs |
| M4-c | `chump-agent-matrix` crate (dogfood matrix as library) | ~2 days |
| M4-d | First `cargo publish` of `chump-agent-lease` + `chump-mcp-lifecycle` | ~30 min when ready |
| M5-a | LoRA / GRPO feature behind `chump-training` (`mistral.rs` + `candle`) | multi-week; scope carefully |
| M5-b | First external crate consumer publicly using `chump-agent-lease` | marketing + evangelism |

---

## Non-goals

- **Catching up to OpenJarvis's star count on a 6-month timeline.** Not feasible without a Stanford lab + PR machine. Instead, aim for technical authority — be the crates other serious Rust agent builders cite.
- **Python bindings as a priority.** OpenJarvis does this because they want researchers; we want Rust builders. Bindings can come, but after the crate ecosystem is solid.
- **Feature-parity with OpenJarvis on 26+ messaging channels.** Our channel breadth (Discord, web PWA, Tauri, CLI, ACP) is already enough for the product story. 22 more thin adapters is boring.

---

## Progress — 2026-04-17 (day 1 of the plan)

**Shipped:**

- [x] `crates/chump-agent-lease/` — first public crate; 10 tests + doc example (`a5b6043`).
- [x] `src/agent_lease.rs` — thin re-export shim; zero callsite churn.
- [x] `src/telemetry_energy.rs` — `ApplePowermetricsMonitor` (working, 8 tests). One-ups OpenJarvis's NVIDIA stub.
- [x] `src/provider_bandit.rs` — Thompson Sampling + UCB1; 9 tests, convergence verified on a 0.8-vs-0.2 reward arm (`e407866`).
- [x] `scripts/chump-bench.sh` + `docs/BENCHMARKS.md` — reproducible public benchmark runner + empty results table ready to populate (`281f71a`).
- [x] `crates/chump-mcp-lifecycle/` — second public crate; 7 tests + doctest; OpenJarvis's `openjarvis-mcp` is 270 LOC stateless, ours is 697 LOC with persistent per-session lifecycle + Drop-cascade reap (`fecf45f`).
- [x] `docs/WHY_CHUMP_NOT_OPENJARVIS.md` — honest public comparison with evidence, not marketing. Includes "when you should pick OpenJarvis, not Chump" section (this commit).
- [x] `docs/LIBRARY_ADOPTION_GUIDE.md` — per-crate consumer guide for external Rust agent builders (this commit).
- [x] This plan doc kept current.

**Not yet shipped (day 2+ work):**

- [ ] `cargo publish` the two extracted crates. Needs crates.io account action — only Jeff can do this.
- [ ] `docs/BENCHMARKS.md` populated with a real run row. Needs a live backend configured to Jeff's daily model.
- [ ] `chump-cognition` extraction (M3-a). Heavy coupling — 17 files ref `blackboard`, 16 ref `precision_controller`. Requires a focused multi-day effort with a worktree + staged migration; not pick-up-at-any-time work.
- [ ] `chump-core` foundations (M3-b). Medium coupling but lots of surface area.
- [ ] `chump-agent-matrix` extraction (M4-c). Medium effort; straightforward pattern copy from the two already-extracted crates.
- [ ] LoRA / GRPO via `mistral.rs` + `candle` (M5-a). Multi-week feature.

## What to do next session

Priority order, cheapest-to-highest-leverage:

1. **Publish the two extracted crates.** 30 minutes once the crates.io credentials are set up. Immediately moves the table in the README from "extracted" to "published on crates.io".
2. **Populate `docs/BENCHMARKS.md`** with a real row from `scripts/chump-bench.sh` against the vLLM-MLX 9B setup. That's the cite-able number we've been talking about.
3. **Begin `chump-cognition` extraction.** Start with the lowest-coupling modules (`consciousness_traits`, `perception`, `holographic_workspace`) and work inward. Partial extraction is better than waiting for a perfect one.
