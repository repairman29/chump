---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# The Chump project story

> What this project is, how it got here, and why the pieces exist together.

If you landed on this repo from GitHub and are trying to figure out what you're looking at — this is the page for you.

---

## What Chump actually is

Chump is an **agentic operating system** — mission: **ship any vision, rescue
any dream.** Not a chatbot, not a framework you assemble a crew with — an OS
that runs a fleet of agents against a real codebase until the vision is
shipped, with the human at ring-0, not in the conductor's chair. See
[docs/ROADMAP.md — "The ChumpOS arc"](../ROADMAP.md) for the current phase
and honest status (it's an arc, not a finished product yet).

That shows up today as four things, and the fact that it is all four is not an accident.

**0. The coordination layer — the fleet of coding agents.**
This is the headline differentiator: a gap registry, file-based leases, an
ambient event stream, and a merge-queue ship pipeline that let many concurrent
coding-agent sessions (Claude Code, opencode, or anything that can push a
branch) work the same repo without stomping each other, hand off work, and
recover from failure. This is what "infra IS the product" means in ROADMAP.md.

**1. A Discord/PWA bot with intent understanding — the optional built-in agent.**
Alongside the coordinator, Chump ships its own agent: connects to local LLMs,
understands natural language, and takes action. Not a chatbot — it creates
tasks, runs code, stores memory, manages GitHub PRs, and operates on a
heartbeat. You ask it to "clean up the stale worktrees" or "run the weekly
report" and it does it, infers what you mean, and asks only when genuinely
ambiguous. This lane is optional — the coordinator works with any agent you
already have.

**2. A consciousness research platform — a bet, not a claim.**
Nine cognitive subsystems are wired into the built-in agent's loop: surprise tracking, belief state, blackboard/global workspace, neuromodulation, precision controller, memory graph, counterfactual reasoning, phi proxy, and holographic workspace. These are not production features. They are empirical interventions — each one can be ablated, A/B tested, and measured. We run controlled trials with A/A controls, Wilson confidence intervals, and multi-axis scoring. The goal is to find out which cognitive structures actually improve AI agent behavior and which ones hurt. See [docs/process/RESEARCH_INTEGRITY.md](../process/RESEARCH_INTEGRITY.md) for what's currently validated and what isn't.

**3. A Rust crate ecosystem.**
As each module matures and its boundaries stabilize, it gets extracted into a standalone publishable crate: `chump-agent-lease`, `chump-perception`, `chump-belief-state`, `chump-messaging`, and more. The extraction pattern is proven and repeatable. This isn't just cleanup — it's how both the coordination layer and the research become reusable infrastructure other agent systems can adopt piece by piece.

These reinforce each other. The coordination layer is what actually ships the vision. The built-in agent (and Discord/PWA surface) is one production harness that surfaces real failure modes. The research platform turns those failure modes into controlled experiments. The crate ecosystem packages what stabilizes.

---

## How it started

The project started as a personal AI coding assistant — a local alternative to cloud-dependent tools. Get a fast local model, give it tools, make it useful. Standard enough premise.

Two things happened that changed its character.

The first was the memory problem. Every session started fresh. The agent could execute tasks but had no continuity — no way to remember that we'd already tried that approach, no way to track what it had built. Fixing this properly (SQLite FTS5 + embedding recall + HippoRAG-inspired associative memory graph) turned out to require more architecture than anticipated. The memory layer became the first "cognitive module" — not by design, just by necessity.

The second was the cognitive science literature. Once you have a system that can be A/B tested, the question "does this help?" becomes answerable. The consciousness and cognitive science literature is full of architectural proposals — global workspace theory, active inference, neuromodulation, predictive coding. Most of these have never been empirically tested in an AI agent context, at all. Chump became the vehicle to test them.

---

## What the experiments have found so far

**This document has been moved to a private repository.** Per-study results
(the Scaffolding U-curve, the neuromodulation ablation, the lessons-block
hallucination channel, and seeded-fact retrieval) are tracked in
`chump-proprietary` (private, need-to-key) so they can be published through
controlled channels rather than scraped from a public repo.

The one publicly-sanctioned finding to date: **instruction injection has
tier-dependent effects — prescriptive lessons help small models on specific
tasks and harm frontier models.** The fix path (gate lessons injection by
model tier rather than remove it) is real and tracked under the
model-tier-aware injection gap; specifics are private.

The full methodology lives in [docs/research/consciousness-framework-paper.md](research/consciousness-framework-paper.md) and [docs/research/CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) (both already correctly stubbed to the private repo). See [docs/process/RESEARCH_INTEGRITY.md](process/RESEARCH_INTEGRITY.md) for what's public-safe to state.

---

## The crate ecosystem: why extract?

As a pure engineering decision, crate extraction creates overhead. But the Chump codebase has a specific problem: the cognitive modules are deeply entangled with each other and with the SQLite schema. Every time we want to test a hypothesis, we're working in a monolith where changes to one module ripple unexpectedly.

The extraction pattern emerged from this:

1. When a module's boundaries stabilize (acceptance criteria pass, no active PRs touching it), extract it.
2. Replace the in-tree module with a re-export shim — zero caller churn.
3. The extracted crate gets its own test suite, its own versioning, and its own `cargo publish` lifecycle.
4. Future ablation studies can swap crate versions in `Cargo.toml` rather than branching the whole repo.

Nine crates are extracted and published as of this writing. The next seven (counterfactual, reflection, memory, blackboard, speculative, neuromodulation, tool-middleware) all require a `db_pool` refactor first — splitting the monolithic `init_schema` into per-module schema files.

---

## The fleet

The project runs on two machines: a Mac (primary development, fast local models) and a Pixel phone (Android ARM, quantized models, low-power continuous operation). The heartbeat system keeps both running: Farmer Brown (task farming), Memory Keeper (memory curation), Sentinel (error monitoring), Oven Tender (web interface), Heartbeat Shepherd (orchestration).

The Mac and Pixel are not redundant — they have different model capacity profiles and different uptime characteristics. The fleet is designed so that the Pixel can continue basic operations when the Mac is off, and the Mac can run expensive A/B studies that the Pixel can't.

Mutual supervision (each machine monitors the other's heartbeat) is implemented. The full fleet coordination spec is in [docs/process/AGENT_COORDINATION.md](AGENT_COORDINATION.md).

---

## Where it is going

Short term:
- Ship the `db_pool` per-module schema refactor to unblock the remaining crate extractions
- Run multi-turn A/B studies (see eval-track gaps) to see if the hallucination effect compounds or washes out across conversation turns
- Implement context-window compaction (see cognition-track gaps) for long sessions

Medium term:
- Full crate ecosystem publish: all 16 identified crates on crates.io with stable APIs
- Cross-family judge runs (three-judge ensemble: Claude + GPT + Gemini) to eliminate single-judge bias from study results
- External collaborator studies: run the same A/B fixture on contributors' hardware to test generalization beyond one operator's setup

Long term, the goal is to make the research findings actionable for anyone building an AI agent — not just Chump users. The cognitive module framework should be expressible as a set of crates + a paper + a study runner that anyone can apply to their own model and task distribution.

---

## How to participate

You don't need to be a Rust developer.

**If you have a GPU or Apple Silicon Mac:** The most valuable thing you can do is run an A/B study. The harness is in `scripts/ab-harness/`, it takes 30-60 minutes, and it costs under $5 in API calls. See [docs/research/RESEARCH_COMMUNITY.md](research/RESEARCH_COMMUNITY.md) for exact instructions and how to submit results.

**If you find a bug:** Use the [GitHub issue template](../.github/ISSUE_TEMPLATE/bug_report.md). Be specific: model name, task, what you expected, what happened.

**If you want to contribute code:** Read [CONTRIBUTING.md](../CONTRIBUTING.md). The short version: pick an open gap from [docs/gaps.yaml](gaps.yaml) (status: open), run `scripts/coord/gap-preflight.sh <GAP-ID>`, create a worktree, ship a small PR. The coordination system exists specifically to make parallel contributions safe — use it.

**If you want to follow the research:** Watch the repo and read the [session syntheses](syntheses/) when they land. Each synthesis captures a phase of work in enough detail to understand what changed and why.

---

## The name

"Chump" is deliberately unheroic. It's a reminder that the project is a tool built in the open, not a product announcement. The name was chosen early, when the project was just a personal assistant that ran on a MacBook. It stuck.
