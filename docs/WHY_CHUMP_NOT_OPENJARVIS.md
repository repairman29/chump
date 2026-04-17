# Chump vs OpenJarvis — honest comparison

**Short version:** OpenJarvis is a Python-first research framework with a Rust backing library. Chump is a Rust-first working agent AND a library ecosystem. If you're building a local-first AI agent in Rust, Chump is the larger, deeper, and more production-hardened option. If you're a researcher who wants to publish results fast with Python bindings and a Stanford citation, OpenJarvis is the mature pick — today.

This doc lays out the comparison without hype, including the parts where they're ahead.

---

## Who is behind each

|   | OpenJarvis | Chump |
|---|---|---|
| Backing | Stanford Scaling Intelligence Lab | Independent (solo builder, open-source) |
| License | Apache 2.0 | MIT |
| First public commit | 2026-02-15 | earlier (solo builder, longer runway) |
| Stars (2026-04-17) | 2,761 | — |
| Language strategy | Python front, Rust backing (PyO3) | Rust-first, no Python bindings (yet) |

OpenJarvis has institutional reach we don't have. They'll accumulate stars and citations faster than we can. Our advantages are technical depth and Rust-native positioning.

## Code size (at 2026-04-17)

|   | OpenJarvis | Chump |
|---|---|---|
| Rust LOC | 26,761 (17 library crates) | 66,620 main + 3,200 in published crates |
| Python LOC | ~15,000 | 0 |
| Public library crates | 17 (all `openjarvis-*`) | 2 (`chump-agent-lease`, `chump-mcp-lifecycle`); more in extraction |

## Where Chump is ahead

### 1. Multi-agent coordination is a first-class system

OpenJarvis does not mention coordination between multiple concurrent agents on the same repo. We do, because we hit the failure mode — two bots editing the same file, no one winning. Our solution:

- [`chump-agent-lease`](../crates/chump-agent-lease/) — path-level optimistic leases; any Rust agent can `cargo add` it.
- Pre-commit hook with five jobs (lease-collision, stomp-warning, gaps.yaml discipline, cargo-fmt, cargo-check). See [`docs/AGENT_COORDINATION.md`](./AGENT_COORDINATION.md).
- Pre-push hook with gap-preflight that stops duplicate implementations before they reach main.
- Dogfood matrix (`scripts/dogfood-matrix.sh`) + nightly scheduled task filing regression tasks automatically.

This exists because we ran 4+ agents in parallel for weeks and fixed each stomp as we found it. That lived experience is in the code; OpenJarvis doesn't have it yet.

### 2. MCP lifecycle is richer

- OpenJarvis `openjarvis-mcp`: 270 LOC, stateless spawn-per-call.
- Chump [`chump-mcp-lifecycle`](../crates/chump-mcp-lifecycle/): 697 LOC, persistent per-session children with `Drop`-cascade reap.

The lifecycle difference matters for MCP servers that do warm-up (embedding indexes, loaded models, open DB connections). Stateless works for a calculator; not for real tools.

### 3. Cognitive substrate

OpenJarvis's agent primitives: ReAct + two role names (`Orchestrator`, `Operative`).

Chump's cognitive substrate (still in-tree under `src/` as of 2026-04-17, `chump-cognition` extraction in progress):

- `neuromodulation.rs` — dopamine/noradrenaline/serotonin-like state modulators that affect temperature, top_p, tool selection threshold.
- `precision_controller.rs` — Explore / Exploit / Balanced / Conservative regime transitions driven by recent surprisal EMA.
- `belief_state.rs` — task uncertainty estimation that gates when the agent asks for clarification vs plows ahead.
- `surprise_tracker.rs` — tool-outcome prediction error tracking, input to the precision controller.
- `blackboard.rs` — global-workspace-style shared salience buffer across modules.
- `counterfactual.rs` — causal graph over tool traces, used for lesson extraction.
- `phi_proxy.rs`, `holographic_workspace.rs` — research-grade extensions.
- `perception.rs` — rule-based pre-LLM task classification + risk assessment.

Empirical backing lives in `docs/CONSCIOUSNESS_AB_RESULTS.md` (A/B studies with `CHUMP_CONSCIOUSNESS_ENABLED`). COG-001 (round-2 with LLM-as-judge + multi-model scaling curves) is an open gap.

**This is our biggest single differentiator vs OpenJarvis.** When `chump-cognition` lands as a crate, the pitch is: "your agents gain a measurable cognitive substrate with an active inference story, not just ReAct."

### 4. Editor-native agent surface via ACP

Chump implements the full [Agent Client Protocol](https://agentclientprotocol.com). Launchable as an agent from Zed, JetBrains IDEs, or any ACP client; write tools prompt for user consent through the editor's UI; file + shell operations delegate to the editor's environment when running on a remote host.

OpenJarvis's browser dashboard + messaging-channel count (26+) is a different product surface. Neither is strictly better; they're targeting different users.

### 5. Defense suite in production

- `scripts/dogfood-matrix.sh` — 8 scenarios run against the live agent on a nightly schedule, filing Chump tasks automatically on any regression.
- `scripts/chump-bench.sh` — public benchmark runner (the counterpart to their "88.7% at interactive latency" claim).
- CI-level `dogfood-matrix --quick` step on every PR.
- Pre-commit `cargo check` guard stops broken-compile commits at the source.

OpenJarvis has an evaluation harness in Python (`openjarvis.evals`) that's more flexible for research workflows. Ours is tighter for production — it caught the Metal crash in task #58 before users hit it.

### 6. Working energy telemetry

- OpenJarvis `openjarvis-telemetry::energy::NvidiaEnergyMonitor` — `is_available()` hardcoded to `false`, `stop()` returns `EnergyReading::default()`. Stubs.
- Chump `src/telemetry_energy.rs::ApplePowermetricsMonitor` — real `powermetrics` integration producing joules/watts/temperature/utilization. Works on Apple Silicon today; NVIDIA scaffold ready for Linux.

The trait shape matches theirs field-for-field so interop is one impl away when they ship working backends.

---

## Where OpenJarvis is ahead

### 1. Adoption + reach

2,761 stars, Stanford lab name, blog post, leaderboard, Python bindings for researchers. We don't match this on any axis and probably won't catch up on raw reach in 2026. Our play is to be the Rust-native *technical* authority; they're the Python-adjacent *research* authority.

### 2. LoRA / GRPO / SFT training on local traces

`openjarvis-learning` is 6,281 LOC covering supervised fine-tuning, LoRA adapters, GRPO, skill discovery, and reward models — a full closed-loop training system. Chump has reflection + lesson extraction (COG-4) but no weight updates.

This is our biggest real gap. Closing it requires either:

1. A `chump-training` crate built on `mistral.rs` + `candle` for Rust-native fine-tuning (preserves our Rust-first story), or
2. A Python interop shim that calls their `openjarvis-learning` under the hood (pragmatic; compromises the story).

Tracked in [`RUST_AGENT_STANDARD_PLAN.md`](./RUST_AGENT_STANDARD_PLAN.md) as M5. Multi-week feature.

### 3. Bandit routing — caught up

Tied now. As of commit `e407866` (M2-a), [`src/provider_bandit.rs`](../src/provider_bandit.rs) implements Thompson Sampling + UCB1 wired into `provider_cascade`. Acceptance tests prove convergence on a 0.8-reward arm vs 0.2.

### 4. Messaging channel breadth

They claim 26+ channels (iMessage, WhatsApp, Telegram, Signal, ...). We have Discord + web PWA + Tauri desktop + CLI + ACP. Enough for our product story; less than theirs for a "personal chief of staff" pitch. Low priority to match — most of their 22-channel advantage is thin adapters.

### 5. Public benchmark number

They have a loud "88.7% of single-turn queries at interactive latency" claim from their Intelligence-Per-Watt research. Ours ([`docs/BENCHMARKS.md`](./BENCHMARKS.md)) has the runner + scaffolding but no published results row yet. Closing this is ~1 day of plumbing + an overnight run.

### 6. Framework polish

Their crates have `cargo doc` badges, a mkdocs site, a leaderboard, and copious README examples. Ours have READMEs + doc comments but no hosted docs site yet. Cosmetic gap; closeable in a few hours per crate when we publish to crates.io.

---

## When you should pick OpenJarvis, not Chump

We'd rather you know than find out the hard way.

- **You're a Python researcher.** Chump has zero Python bindings; OpenJarvis has PyO3 + a `pip install` story.
- **You need fine-tuning today.** Chump's M5 is weeks out; OpenJarvis's training crate is live.
- **You want a framework with thousands of stars by the first day.** We'll take time to earn adoption.
- **You need messaging-channel breadth** (iMessage/WhatsApp/Telegram/Signal in one deploy). We have fewer.
- **You want a research-citable framework today.** Stanford paper + blog post > solo-builder GitHub.

## When you should pick Chump, not OpenJarvis

- **You're building a Rust-first agent.** OpenJarvis is a Python wrapper around a Rust backing library; Chump is Rust all the way down, no PyO3 glue to maintain.
- **You need multi-agent coordination.** `chump-agent-lease` + the pre-commit hook suite is a novel cooperative protocol nobody else ships. When you run 3+ concurrent agents on one repo, this goes from "nice to have" to "the difference between shipping and silent data loss."
- **You need per-session MCP server lifecycle.** `chump-mcp-lifecycle` is the crate; openjarvis-mcp is stateless spawn-per-call.
- **You want a cognitive substrate.** Active inference + neuromodulation + precision controller (vs ReAct + role names). Empirical A/B data in `docs/CONSCIOUSNESS_AB_RESULTS.md`.
- **You want ACP editor integration.** Zed + JetBrains native.
- **You want production hardening lessons from real use.** See commits tagged `fix(task #58)`, `fix(task #59)`, the `delegate_summarize` saga — the kind of bugs you only find by running the system continuously.

---

## Roadmap alignment

What we plan to do that puts us at clear parity or ahead on their remaining advantages:

| Gap | Our plan | Tracking |
|---|---|---|
| Public benchmark number | Populate `docs/BENCHMARKS.md` with a real run result next to their 88.7% | M3 |
| Crates on crates.io | Publish `chump-agent-lease` + `chump-mcp-lifecycle` first; others as extracted | M2–M5 |
| `chump-cognition` extraction | Most-distinctive crate; cognition is what OpenJarvis genuinely lacks | M3 |
| LoRA/GRPO | `chump-training` feature flag atop mistral.rs + candle | M5 |
| Hosted docs site | After first crate publish, set up docs.rs + project site | M4 |
| Python bindings | After Rust-native story is solid; optional for researcher reach | M6 |

---

## Contributing

If you're considering which ecosystem to build on, or reading this as an open-source contributor: **pick the one whose gaps you want to close.** We'd rather have a strong OpenJarvis and a strong Chump than a duopoly where both lose to the next cloud thing. Both projects are Apache/MIT and either will welcome your work.

If your contribution is specifically about Rust-native primitives, Chump is the more targeted home. If it's Python ergonomics or a research evaluation, OpenJarvis is probably the right address.

---

_Last updated: 2026-04-17. This comparison is honest and revised when facts change; PRs that surface new facts — ours or theirs — are welcome._
