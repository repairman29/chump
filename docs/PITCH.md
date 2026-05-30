# Chump — Why It Exists

> For collaborators, grant readers, and external reviewers. If you want a live
> demo walkthrough, read [docs/DEMO_5MIN.md](DEMO_5MIN.md) instead.
> If you want the full operator guide, start at [README.md](../README.md).

---

## What Chump is

Chump is a multi-agent fleet coordinator. It takes natural-language gap
descriptions — filed to a SQLite registry — and turns them into merged pull
requests, autonomously, without human review at every step. A fleet of coding
agents (Claude Code, opencode, Codex CLI, or anything that can push a branch)
picks gaps from the queue, claims atomic file ownership via lease files, commits
work to isolated git worktrees, and ships through a merge-queue pipeline.

Chump is not an LLM wrapper. The models are interchangeable and optional. The
thing that makes agents productive is the **coordination layer**: the gap
registry, the lease graph, the ambient event stream, the per-gap briefing
memory.

---

## Why now

Commodity hardware is crossing a threshold. A $500 mini-PC can serve a capable
7B model today; a mesh of Raspberry Pis can collectively run a 70B model via
distributed inference. The model access problem for solo developers is close to
solved.

The coordination problem is not. Spawning agents against the same codebase
without a substrate produces chaos: agents overwrite each other's changes, claim
the same task twice, ship conflicting PRs, and stall on flaky tests with no
recovery. Every hour of agent time gets wasted on collision recovery that a
20-line lease file would have prevented.

Chump is the coordination layer that was missing — built to run on hardware a
solo developer already owns, with models they can run locally, with no API bill.

---

## Who it is for

Engineers who have already tried "spawn more agents" and watched it fall apart.
People who understand what a merge conflict costs when six agents hit the same
file simultaneously. Teams with a real backlog — hundreds of filed tasks, not a
handful — who need something to grind through it overnight without babysitting.

Chump is not for people who want to prompt an AI once and review the result —
a chat interface handles that. Chump is for people who want a fleet that runs
for hours without input, produces real PRs, and tells the operator what
shipped, what was skipped, and why.

---

## How it differs

The bespoke coordination layer answers "why not just use GitHub Issues and a
few agent sessions?" because GitHub Issues have no atomicity, no lease graph,
and no ambient stream. Two agents claiming the same issue simultaneously corrupt
each other's branches. There is no signal when a worker goes silent.

Chump's substrate provides those things:

- **Lease atomicity** — `chump claim` does a fetch, health check, and SQLite
  write in one transaction. One agent wins; the rest move on cleanly.
- **Ambient event stream** — every agent gets peripheral vision of the whole
  fleet: silent workers, edit bursts, PR stalls, cost cap warnings, all live.
- **NATS push routing** — when a broker is available, the coordinator publishes
  work envelopes by priority, skill class, and target machine. Degrades cleanly
  to pull mode when offline.
- **Gap briefing memory** — each gap carries per-session context injected at
  claim time, so an agent picking up where another left off starts informed.

The 4-pillar mission — **Credible** (measured claims only), **Effective**
(user-facing output), **Resilient** (self-correcting under failure),
**Zero-Waste** (no redundant work) — is encoded into the gap registry as a
priority balance constraint, not just a document.

```bash
bash scripts/dispatch/fleet-brief.sh          # 60-second operator briefing
chump fleet doctor --slo-check                # exits non-zero on any health breach
tail -f .chump-locks/ambient.jsonl | jq -r '.kind'   # live fleet event stream
```

---

## What is shipped today vs. what is coming

**Working now:**
- Atomic gap claim across concurrent agents — no race conditions observed across
  72+ hours of 4-worker fleet operation
- Full ship pipeline: `chump claim` → commit → `bot-merge.sh --auto-merge` → merged PR
- Local-LLM path via Ollama and vLLM — no cloud API required for the coordinator

**In progress:**
- Predictive collision detection and skill-aware gap routing
- Cross-agent lesson propagation (lesson store exists; peer injection is queued)
- `chump preflight` as a single local CI command (wrapping fmt/clippy/check)

**Honest caveat:** the cognitive-architecture layer (neuromodulation, surprisal
tracking) is experimental — the first A/B returned null at the preregistered
threshold. The coordination layer is not experimental; it runs production workloads.

---

## Where to start

- **Install and first run:** [README.md quickstart](../README.md#try-chump-in-5-minutes) —
  `brew install chump`, `chump init`, first fleet in five steps
- **All shipped capabilities:** [docs/CAPABILITIES_REGISTRY.json](CAPABILITIES_REGISTRY.json) —
  machine-readable index of every CLI command, flag, and agent capability
- **Full operator and agent guide:** [AGENTS.md](../AGENTS.md) — tool-agnostic
  reference for any coding agent or operator working in this repo
- **Team-tier substrate demo (Marcus M-D):** [docs/strategy/CHUMP_PE_SUITE_DEMO_5MIN.md](strategy/CHUMP_PE_SUITE_DEMO_5MIN.md) —
  5-beat runbook showing 14 curators deliberating in real time; run via `bash scripts/demo/chump-pe-suite-demo.sh` (INFRA-2234)
