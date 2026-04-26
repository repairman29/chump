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

Chump is three things at once, and the fact that it is all three is not an accident.

**1. A Discord bot with intent understanding.**
The most visible interface is a Discord bot that connects to local LLMs, understands natural language from users, and takes action. Not a chatbot — it creates tasks, runs code, stores memory, manages GitHub PRs, and operates on a heartbeat. You ask it to "clean up the stale worktrees" or "run the weekly report" and it does it, infers what you mean, and asks only when genuinely ambiguous.

**2. A consciousness research platform.**
Nine cognitive subsystems are wired into every agent loop: surprise tracking, belief state, blackboard/global workspace, neuromodulation, precision controller, memory graph, counterfactual reasoning, phi proxy, and holographic workspace. These are not production features. They are empirical interventions — each one can be ablated, A/B tested, and measured. We run controlled trials with A/A controls, Wilson confidence intervals, and multi-axis scoring. The goal is to find out which cognitive structures actually improve AI agent behavior and which ones hurt.

**3. A Rust crate ecosystem.**
As each module matures and its boundaries stabilize, it gets extracted into a standalone publishable crate: `chump-agent-lease`, `chump-perception`, `chump-belief-state`, `chump-messaging`, and more. The extraction pattern is proven and repeatable. This isn't just cleanup — it's how the research becomes reusable infrastructure for other agent frameworks.

These three identities reinforce each other. The Discord bot is the production harness that surfaces real failure modes. The research platform turns those failure modes into controlled experiments. The crate ecosystem packages what the experiments confirm.

---

## How it started

The project started as a personal AI coding assistant — a local alternative to cloud-dependent tools. Get a fast local model, give it tools, make it useful. Standard enough premise.

Two things happened that changed its character.

The first was the memory problem. Every session started fresh. The agent could execute tasks but had no continuity — no way to remember that we'd already tried that approach, no way to track what it had built. Fixing this properly (SQLite FTS5 + embedding recall + HippoRAG-inspired associative memory graph) turned out to require more architecture than anticipated. The memory layer became the first "cognitive module" — not by design, just by necessity.

The second was the cognitive science literature. Once you have a system that can be A/B tested, the question "does this help?" becomes answerable. The consciousness and cognitive science literature is full of architectural proposals — global workspace theory, active inference, neuromodulation, predictive coding. Most of these have never been empirically tested in an AI agent context, at all. Chump became the vehicle to test them.

---

## What the experiments have found so far

This is a summary. The full methodology and raw data are in [docs/research/consciousness-framework-paper.md](research/consciousness-framework-paper.md) and [docs/research/CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md).

### The Scaffolding U-curve

When scaffolding (the nine-module cognitive layer) is added to local models, the effect on task performance depends on model size:

- **1B and 14B models**: +10pp pass rate — they benefit
- **3B and 7B models**: −5pp — they are hurt
- **8B models**: approximately neutral

This is a real empirical result with A/A controls. The interpretation: small models don't have the capacity to use the scaffolding productively (it's noise); mid-range models are confused by it; larger models can leverage it. We have not tested 32B/70B models yet; the prediction is increasing benefit but that is unconfirmed.

**Operational implication:** The cognitive modules are gated by model tier in production. A 3B model running a Discord command doesn't pay the scaffolding cost. A 14B model doing a long research task does.

### The neuromodulation ablation

Ablating the neuromodulation module on qwen3:8b showed: **+12pp pass rate on structured tasks, but −0.60 tool efficiency delta on dynamic tasks**. Both effects are real. The trade-off is context-dependent — neuromodulation helps on focused tasks, hurts on tasks that require flexible tool selection.

### The lessons-block hallucination channel

This is the most significant finding so far, and the one with the clearest path to a fix.

Injecting a "Lessons from prior episodes" block into the system prompt consistently increases fake-tool-call emission by **+0.14 pp mean** (≈ +0.0014 absolute rate; range +0.13 to +0.16 pp across three task fixtures). This was measured at n=100 per cell with cloud frontier models (claude-haiku-4-5), with A/A controls showing the noise floor at 0.013 pp mean delta — making the A/B effect **10.7× the calibrated noise floor**.

This is a documented harm channel. It means the memory system that was built to help agents learn from past mistakes is, in its current form, teaching weaker models to hallucinate tool calls.

The fix is not to remove the lessons block — it's to gate which models see it. Strong models (32B+) can use lessons productively. Weak models cannot. This was confirmed by COG-016: targeted directive injection using the same lessons channel on a capable model eliminated the hallucination effect entirely (delta neutralized from +0.14 to near-zero).

### Seeded-fact retrieval (Study 5)

To confirm the lessons block actually surfaces stored information (as opposed to just adding noise), we ran a retrieval study: inject 10 arbitrary "seeded directives" (unforgeable values like specific port numbers, timestamps, and tokens) into the causal-lessons database and test whether the model outputs them. Mode A (with lessons block): **40% pass rate**. Mode B (without): **5% pass rate**. Delta: **35pp**.

This confirms the mechanism works for retrieval. The hallucination problem is not that the channel is broken — it's that weak models can't distinguish between using the lessons and fabricating the actions.

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
- Run multi-turn A/B studies (EVAL-024) to see if the hallucination effect compounds or washes out across conversation turns
- Implement context-window compaction (COG-019) for long sessions

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

**If you want to contribute code:** Read [CONTRIBUTING.md](../CONTRIBUTING.md). The short version: pick an open gap from [docs/gaps.yaml](gaps.yaml) (status: open), run `scripts/gap-preflight.sh <GAP-ID>`, create a worktree, ship a small PR. The coordination system exists specifically to make parallel contributions safe — use it.

**If you want to follow the research:** Watch the repo and read the [session syntheses](syntheses/) when they land. Each synthesis captures a phase of work in enough detail to understand what changed and why.

---

## The name

"Chump" is deliberately unheroic. It's a reminder that the project is a tool built in the open, not a product announcement. The name was chosen early, when the project was just a personal assistant that ran on a MacBook. It stuck.
